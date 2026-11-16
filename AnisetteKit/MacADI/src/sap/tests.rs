use super::engine::{Engine, SCRATCH_BASE};

#[test]
#[ignore = "requires pinned Apple guest assets; run explicitly"]
fn opens_modern_adi_with_real_assets() {
    let root = std::env::var("MODERN_ADI_ASSETS").expect("set MODERN_ADI_ASSETS");
    let bundle = super::runtime::Bundle::load(std::path::Path::new(&root)).unwrap();
    let adi = super::modern_adi::ModernADI::open(&bundle, &[1;16], &[]).unwrap();
    assert!(adi.state().is_err(), "fresh identity must not report provisioned state");
}


#[test]
fn platform_xpc_data_roundtrip() {
    let mut engine = Engine::new().unwrap();
    engine.register_platform_services().unwrap();
    engine.mem_write(SCRATCH_BASE, b"payload").unwrap();
    let create = engine.resolve("_xpc_dictionary_create_empty").unwrap();
    let object = engine.invoke(create, &[]).unwrap();
    let set = engine.resolve("_xpc_dictionary_set_data").unwrap();
    engine.invoke(set, &[object, 0, SCRATCH_BASE, 7]).unwrap();
    let get = engine.resolve("_xpc_dictionary_get_data").unwrap();
    let data = engine.invoke(get, &[object, 0, SCRATCH_BASE + 32]).unwrap();
    assert_eq!(engine.read_u64(SCRATCH_BASE + 32).unwrap(), 7);
    assert_eq!(engine.mem_read(data, 7).unwrap(), b"payload");
}

#[test]
fn platform_virtual_adi_file_roundtrip() {
    let mut engine = Engine::new().unwrap();
    engine.register_platform_services().unwrap();
    let path = b"/var/db/fpsd/adi/adi.pb\0";
    engine.mem_write(SCRATCH_BASE, path).unwrap();
    engine.mem_write(SCRATCH_BASE + 64, b"state").unwrap();
    let open = engine.resolve("_open").unwrap();
    assert_eq!(engine.invoke(open, &[SCRATCH_BASE, 0x200]).unwrap(), 5);
    let write = engine.resolve("_write").unwrap();
    assert_eq!(engine.invoke(write, &[5, SCRATCH_BASE + 64, 5]).unwrap(), 5);
    engine.invoke(open, &[SCRATCH_BASE, 0]).unwrap();
    let read = engine.resolve("_read").unwrap();
    assert_eq!(engine.invoke(read, &[5, SCRATCH_BASE + 128, 10]).unwrap(), 5);
    assert_eq!(engine.mem_read(SCRATCH_BASE + 128, 5).unwrap(), b"state");
}
