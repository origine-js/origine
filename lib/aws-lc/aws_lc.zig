//! Zig view of AWS-LC's public C API: the headers with `BORINGSSL_PREFIX` defined, so declarations
//! match the `aws_lc_0_47_0_*` symbols of the Zig-built library. Link `aws_lc_crypto` (the package's
//! artifact) to resolve them; see docs/aws-lc.md.

pub const c = @cImport({
    @cInclude("openssl/crypto.h");
    @cInclude("openssl/evp.h");
    @cInclude("openssl/ssl.h");
});
