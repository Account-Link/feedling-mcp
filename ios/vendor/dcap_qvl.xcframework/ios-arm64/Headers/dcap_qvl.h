// dcap_qvl.h — C FFI surface for Phala-Network/dcap-qvl, called from
// Feedling's iOS audit path (see ios/vendor/build-dcap-qvl.sh).
//
// The Rust crate exposes every output via a caller-provided callback so
// the Rust side doesn't need to own the result buffer. Each function:
//   - returns 0 on success, non-zero on error
//   - writes the result (JSON) by invoking `cb(ptr, len, user_data)`
//     exactly once. On error, `cb` receives a UTF-8 error message
//     (still JSON-free) and the function returns ERR_GENERIC.
//
// Swift callers wrap these by passing a `@convention(c)` callback that
// copies the bytes into a heap-allocated buffer, then parse the JSON.
//
// Full definitions in ios/vendor/dcap-qvl/src/ffi.rs.

#ifndef DCAP_QVL_H
#define DCAP_QVL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DCAP_QVL_OK            0
#define DCAP_QVL_ERR_GENERIC   1
#define DCAP_QVL_ERR_CALLBACK  2

/// Callback invoked by each dcap_* function with its JSON output.
/// Return 0 from the callback on success, non-zero to signal caller error.
typedef int32_t (*dcap_output_callback_t)(const uint8_t *data,
                                          size_t len,
                                          void *user_data);

/// Parse a TDX/SGX quote structurally. Output is a JSON object shaped
/// like `FfiQuote` in ffi.rs (header, report, cert_type, cert_chain_pem,
/// fmspc, ca, quote_type, …).
int32_t dcap_parse_quote_cb(const uint8_t *quote,
                            size_t quote_len,
                            dcap_output_callback_t cb,
                            void *user_data);

/// Verify a quote against caller-supplied Intel collateral (JSON of
/// `QuoteCollateralV3`) using the dstack-internal pinned root. Output
/// is JSON of `FfiVerifiedReport`: { status, advisory_ids, report,
/// ppid, qe_status, platform_status }.
int32_t dcap_verify_cb(const uint8_t *quote,
                       size_t quote_len,
                       const uint8_t *collateral_json,
                       size_t coll_len,
                       uint64_t now_secs,
                       dcap_output_callback_t cb,
                       void *user_data);

/// Same as dcap_verify_cb, but the caller supplies the trusted root CA
/// (DER-encoded Intel SGX Root CA bytes). Feedling uses this so the
/// root we trust is the one bundled in the app (`IntelSGXRootCA.der`).
int32_t dcap_verify_with_root_ca_cb(const uint8_t *quote,
                                    size_t quote_len,
                                    const uint8_t *collateral_json,
                                    size_t coll_len,
                                    const uint8_t *root_ca_der,
                                    size_t root_ca_len,
                                    uint64_t now_secs,
                                    dcap_output_callback_t cb,
                                    void *user_data);

/// Parse the Intel SGX Extensions out of a PCK PEM blob. Output JSON
/// is `FfiPckExtension` { ppid, cpu_svn, pce_svn, pce_id, fmspc,
/// sgx_type, raw_extension }.
int32_t dcap_parse_pck_extension_from_pem_cb(const uint8_t *pem,
                                             size_t pem_len,
                                             dcap_output_callback_t cb,
                                             void *user_data);

#ifdef __cplusplus
}
#endif

#endif /* DCAP_QVL_H */
