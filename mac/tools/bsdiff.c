/* bsdiff: BSDIFF40 patch maker (algorithm and format by Colin Percival, BSD licence). Output is read by /usr/bin/bspatch. */
#include <bzlib.h>
#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MIN(x, y) (((x) < (y)) ? (x) : (y))

static void split(int64_t *I, int64_t *V, int64_t start, int64_t len, int64_t h) {
	int64_t i, j, k, x, tmp, jj, kk;
	if (len < 16) {
		for (k = start; k < start + len; k += j) {
			j = 1; x = V[I[k] + h];
			for (i = 1; k + i < start + len; i++) {
				if (V[I[k + i] + h] < x) { x = V[I[k + i] + h]; j = 0; }
				if (V[I[k + i] + h] == x) { tmp = I[k + j]; I[k + j] = I[k + i]; I[k + i] = tmp; j++; }
			}
			for (i = 0; i < j; i++) V[I[k + i]] = k + j - 1;
			if (j == 1) I[k] = -1;
		}
		return;
	}
	x = V[I[start + len / 2] + h]; jj = 0; kk = 0;
	for (i = start; i < start + len; i++) { if (V[I[i] + h] < x) jj++; if (V[I[i] + h] == x) kk++; }
	jj += start; kk += jj; i = start; j = 0; k = 0;
	while (i < jj) {
		if (V[I[i] + h] < x) i++;
		else if (V[I[i] + h] == x) { tmp = I[i]; I[i] = I[jj + j]; I[jj + j] = tmp; j++; }
		else { tmp = I[i]; I[i] = I[kk + k]; I[kk + k] = tmp; k++; }
	}
	while (jj + j < kk) {
		if (V[I[jj + j] + h] == x) j++;
		else { tmp = I[jj + j]; I[jj + j] = I[kk + k]; I[kk + k] = tmp; k++; }
	}
	if (jj > start) split(I, V, start, jj - start, h);
	for (i = 0; i < kk - jj; i++) V[I[jj + i]] = kk - 1;
	if (jj == kk - 1) I[jj] = -1;
	if (start + len > kk) split(I, V, kk, start + len - kk, h);
}

static void qsufsort(int64_t *I, int64_t *V, const uint8_t *old, int64_t oldsize) {
	int64_t buckets[256], i, h, len;
	for (i = 0; i < 256; i++) buckets[i] = 0;
	for (i = 0; i < oldsize; i++) buckets[old[i]]++;
	for (i = 1; i < 256; i++) buckets[i] += buckets[i - 1];
	for (i = 255; i > 0; i--) buckets[i] = buckets[i - 1];
	buckets[0] = 0;
	for (i = 0; i < oldsize; i++) I[++buckets[old[i]]] = i;
	I[0] = oldsize;
	for (i = 0; i < oldsize; i++) V[i] = buckets[old[i]];
	V[oldsize] = 0;
	for (i = 1; i < 256; i++) if (buckets[i] == buckets[i - 1] + 1) I[buckets[i]] = -1;
	I[0] = -1;
	for (h = 1; I[0] != -(oldsize + 1); h += h) {
		len = 0;
		for (i = 0; i < oldsize + 1;) {
			if (I[i] < 0) { len -= I[i]; i -= I[i]; }
			else { if (len) I[i - len] = -len; len = V[I[i]] + 1 - i; split(I, V, i, len, h); i += len; len = 0; }
		}
		if (len) I[i - len] = -len;
	}
	for (i = 0; i < oldsize + 1; i++) I[V[i]] = i;
}

static int64_t matchlen(const uint8_t *a, int64_t alen, const uint8_t *b, int64_t blen) {
	int64_t i;
	for (i = 0; i < alen && i < blen; i++) if (a[i] != b[i]) break;
	return i;
}

static int64_t search(const int64_t *I, const uint8_t *old, int64_t oldsize, const uint8_t *new, int64_t newsize,
                      int64_t st, int64_t en, int64_t *pos) {
	int64_t x, y;
	if (en - st < 2) {
		x = matchlen(old + I[st], oldsize - I[st], new, newsize);
		y = matchlen(old + I[en], oldsize - I[en], new, newsize);
		if (x > y) { *pos = I[st]; return x; } else { *pos = I[en]; return y; }
	}
	x = st + (en - st) / 2;
	if (memcmp(old + I[x], new, MIN(oldsize - I[x], newsize)) < 0) return search(I, old, oldsize, new, newsize, x, en, pos);
	return search(I, old, oldsize, new, newsize, st, x, pos);
}

static void offtout(int64_t x, uint8_t *buf) {
	int64_t y = x < 0 ? -x : x;
	for (int i = 0; i < 8; i++) { buf[i] = y % 256; y /= 256; }
	if (x < 0) buf[7] |= 0x80;
}

static uint8_t *readall(const char *p, int64_t *size) {
	int fd = open(p, O_RDONLY); struct stat st;
	if (fd < 0 || fstat(fd, &st) != 0) err(1, "%s", p);
	uint8_t *b = malloc(st.st_size + 1); int64_t got = 0;
	while (got < st.st_size) { ssize_t n = read(fd, b + got, st.st_size - got); if (n <= 0) err(1, "read %s", p); got += n; }
	close(fd); *size = st.st_size; return b;
}

static void bzw(BZFILE *bz, void *p, int n) { int e; BZ2_bzWrite(&e, bz, p, n); if (e != BZ_OK) errx(1, "bzwrite %d", e); }

int main(int argc, char **argv) {
	if (argc != 4) errx(1, "usage: bsdiff oldfile newfile patchfile");
	int64_t oldsize, newsize; uint8_t *old = readall(argv[1], &oldsize), *new = readall(argv[2], &newsize);
	int64_t *I = malloc((oldsize + 1) * sizeof(int64_t)), *V = malloc((oldsize + 1) * sizeof(int64_t));
	if (!I || !V) err(1, "malloc");
	qsufsort(I, V, old, oldsize); free(V);
	uint8_t *db = malloc(newsize + 1), *eb = malloc(newsize + 1); int64_t dblen = 0, eblen = 0;
	FILE *pf = fopen(argv[3], "w"); if (!pf) err(1, "%s", argv[3]);
	uint8_t header[32]; memcpy(header, "BSDIFF40", 8); offtout(0, header + 8); offtout(0, header + 16); offtout(newsize, header + 24);
	if (fwrite(header, 32, 1, pf) != 1) err(1, "write");
	int e; BZFILE *bz = BZ2_bzWriteOpen(&e, pf, 9, 0, 0); if (e != BZ_OK) errx(1, "bzopen");
	int64_t scan = 0, len = 0, pos = 0, lastscan = 0, lastpos = 0, lastoffset = 0, oldscore, scsc, s, Sf, lenf, Sb, lenb, overlap, Ss, lens, i;
	uint8_t buf[8];
	while (scan < newsize) {
		oldscore = 0;
		for (scsc = scan += len; scan < newsize; scan++) {
			len = search(I, old, oldsize, new + scan, newsize - scan, 0, oldsize, &pos);
			for (; scsc < scan + len; scsc++) if (scsc + lastoffset < oldsize && old[scsc + lastoffset] == new[scsc]) oldscore++;
			if ((len == oldscore && len != 0) || len > oldscore + 8) break;
			if (scan + lastoffset < oldsize && old[scan + lastoffset] == new[scan]) oldscore--;
		}
		if (len != oldscore || scan == newsize) {
			s = 0; Sf = 0; lenf = 0;
			for (i = 0; lastscan + i < scan && lastpos + i < oldsize;) { if (old[lastpos + i] == new[lastscan + i]) s++; i++; if (s * 2 - i > Sf * 2 - lenf) { Sf = s; lenf = i; } }
			lenb = 0;
			if (scan < newsize) { s = 0; Sb = 0; for (i = 1; scan >= lastscan + i && pos >= i; i++) { if (old[pos - i] == new[scan - i]) s++; if (s * 2 - i > Sb * 2 - lenb) { Sb = s; lenb = i; } } }
			if (lastscan + lenf > scan - lenb) {
				overlap = (lastscan + lenf) - (scan - lenb); s = 0; Ss = 0; lens = 0;
				for (i = 0; i < overlap; i++) {
					if (new[lastscan + lenf - overlap + i] == old[lastpos + lenf - overlap + i]) s++;
					if (new[scan - lenb + i] == old[pos - lenb + i]) s--;
					if (s > Ss) { Ss = s; lens = i + 1; }
				}
				lenf += lens - overlap; lenb -= lens;
			}
			for (i = 0; i < lenf; i++) db[dblen + i] = new[lastscan + i] - old[lastpos + i];
			for (i = 0; i < (scan - lenb) - (lastscan + lenf); i++) eb[eblen + i] = new[lastscan + lenf + i];
			dblen += lenf; eblen += (scan - lenb) - (lastscan + lenf);
			offtout(lenf, buf); bzw(bz, buf, 8);
			offtout((scan - lenb) - (lastscan + lenf), buf); bzw(bz, buf, 8);
			offtout((pos - lenb) - (lastpos + lenf), buf); bzw(bz, buf, 8);
			lastscan = scan - lenb; lastpos = pos - lenb; lastoffset = pos - scan;
		}
	}
	BZ2_bzWriteClose(&e, bz, 0, NULL, NULL);
	long ctrl_end = ftell(pf); offtout(ctrl_end - 32, header + 8);
	bz = BZ2_bzWriteOpen(&e, pf, 9, 0, 0); for (int64_t o = 0; o < dblen; o += 1 << 30) bzw(bz, db + o, (int)MIN(dblen - o, 1 << 30)); BZ2_bzWriteClose(&e, bz, 0, NULL, NULL);
	long diff_end = ftell(pf); offtout(diff_end - ctrl_end, header + 16);
	bz = BZ2_bzWriteOpen(&e, pf, 9, 0, 0); for (int64_t o = 0; o < eblen; o += 1 << 30) bzw(bz, eb + o, (int)MIN(eblen - o, 1 << 30)); BZ2_bzWriteClose(&e, bz, 0, NULL, NULL);
	if (fseek(pf, 0, SEEK_SET) != 0 || fwrite(header, 32, 1, pf) != 1) err(1, "header");
	if (fclose(pf) != 0) err(1, "close");
	return 0;
}
