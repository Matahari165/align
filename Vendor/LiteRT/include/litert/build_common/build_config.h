#ifndef LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define LITERT_BUILD_COMMON_BUILD_CONFIG_H_

// Le smoke test ne demande que le runtime CPU. Les accélérateurs seront
// évalués séparément après la preuve de parité BlazePose.
#define LITERT_BUILD_CONFIG_DISABLE_GPU 1
#define LITERT_BUILD_CONFIG_DISABLE_NPU 1
#define LITERT_DISABLE_GPU
#define LITERT_DISABLE_NPU

#endif  // LITERT_BUILD_COMMON_BUILD_CONFIG_H_
