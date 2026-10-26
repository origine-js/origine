// Programs have `print` but not the REPL's global `api`.
print("hello", 1, { a: 1 });

// @ts-expect-error `api` is a global only in the REPL ("@origine/types/repl"); programs get it from main(api)
api.fs;
