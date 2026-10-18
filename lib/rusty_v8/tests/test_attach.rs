//! A V8 initialized outside the crate (as lib/v8_zig's `Engine` does) is joined with
//! `v8::V8::attach_initialized`; both sides then share one platform and one heap setup.

use std::ffi::c_void;

unsafe extern "C" {
  fn v8__Platform__NewDefaultPlatform(
    thread_pool_size: i32,
    idle_task_support: bool,
  ) -> *mut c_void;
  fn v8__V8__InitializePlatform(platform: *mut c_void);
  fn v8__V8__Initialize();
}

#[test]
fn attach_to_externally_initialized_v8() {
  // What the Zig Engine does, without going through this crate's wrappers.
  unsafe {
    let platform = v8__Platform__NewDefaultPlatform(0, false);
    v8__V8__InitializePlatform(platform);
    v8__V8__Initialize();
    v8::V8::attach_initialized(platform.cast());
  }

  let isolate = &mut v8::Isolate::new(Default::default());
  v8::scope!(let scope, isolate);
  let context = v8::Context::new(scope, Default::default());
  let scope = &mut v8::ContextScope::new(scope, context);
  let code = v8::String::new(scope, "[1, 2, 3].map(x => x * 2).join('-')").unwrap();
  let result = v8::Script::compile(scope, code, None)
    .unwrap()
    .run(scope)
    .unwrap();
  assert_eq!(result.to_rust_string_lossy(scope), "2-4-6");
}
