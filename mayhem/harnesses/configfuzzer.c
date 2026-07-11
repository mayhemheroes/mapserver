/* Copyright 2022 Google LLC
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "cpl_conv.h"
#include "cpl_string.h"
#include "src/mapserver.h"

#define kMinInputLength 10
#define kMaxInputLength 10240

extern int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size);
extern int LLVMFuzzerInitialize(int *argc, char ***argv);

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void)argc;
  (void)argv;
  return 0;
}

extern int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {

  if (Size < kMinInputLength || Size > kMaxInputLength) {
    return 1;
  }

  /* CPLGenerateTempFilename(NULL) returns a relative path (e.g. "./_1_1")
   * which is only writable when cwd is writable.  Mayhem runs fuzzers from
   * the image root "/" (read-only), so fopen() fails and msLoadConfig() is
   * never reached — 0 edges.  Use an explicit /tmp path instead. */
  char tmpname[64];
  snprintf(tmpname, sizeof(tmpname), "/tmp/ms_cfg_fuzz_%d.config", getpid());
  char *filename = msStrdup(tmpname);
  FILE *fp = fopen(filename, "wb");
  if (!fp) {
    msFree(filename);
    return 1;
  }
  fwrite(Data, Size, 1, fp);
  fclose(fp);

  msFreeConfig(msLoadConfig(filename));
  VSIUnlink(filename);
  msFree(filename);
  msResetErrorList();

  return 0;
}
