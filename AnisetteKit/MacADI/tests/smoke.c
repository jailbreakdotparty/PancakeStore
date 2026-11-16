#include "MacADICore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 3;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    rewind(file);
    uint8_t *image = malloc(size);
    if (fread(image, 1, size, file) != (size_t)size) return 4;
    fclose(file);
    AdiHandle *h = NULL;
    int32_t rc = adi_open(image, size, &h);
    free(image);
    if (rc != 0) {
        char error[512] = {0};
        adi_last_error(error, sizeof(error));
        fprintf(stderr, "adi_open: %d %s\n", rc, error);
        return 5;
    }
    const uint8_t id[16] = {0};
    if (adi_set_host_uuid(h, id) != 0) return 6;
    AdiBuf mid = {0}, otp = {0};
    uint64_t routing = 0;
    rc = adi_headers(h, -2, &mid, &otp, &routing);
    char error[512] = {0};
    adi_last_error(error, sizeof(error));
    printf("adi_headers(-2): %d (%s)\n", rc, error);
    if (rc == 0) { adi_buf_free(mid); adi_buf_free(otp); }
    adi_close(h);
    return rc == -2 ? 0 : 7; /* freshly created machine is not provisioned */
}
