// Native port of ipatool v2.8.0 internal/sap/machine/shim_platform.go/ioaes.go.
// Copyright (c) 2021 Majd Alfhaily. MIT (SourcesSAP/LICENSE.ipatool).
use super::engine::*;
use crate::Error;
use aes::{Aes128, cipher::{BlockEncrypt, BlockDecrypt, KeyInit, generic_array::GenericArray}};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};
use unicorn_engine::RegisterARM64;

pub type FairPlayHandler = Box<dyn FnMut(&[u8], &[u8], usize) -> Result<(Vec<u8>, Vec<u8>, i32), String>>;
pub type MachRPCHandler = Box<dyn FnMut(&[u8], usize) -> Result<Vec<u8>, String>>;
pub const ADI_PATH: &str = "/var/db/fpsd/adi/adi.pb";
const FAKE: u64 = u64::MAX;

fn read(uc: &Uc<'_>, a: u64, n: u64) -> Result<Vec<u8>, String> {
    let n = checked_size(n)?;
    if n == 0 { return Ok(Vec::new()); }
    uc.mem_read_as_vec(a, n).map_err(ue)
}
fn write(uc: &mut Uc<'_>, a: u64, data: &[u8]) -> Result<(), String> {
    if data.is_empty() { return Ok(()); }
    uc.mem_write(a, data).map_err(ue)
}
fn u64_at(uc: &Uc<'_>, a: u64) -> Result<u64, String> {
    Ok(u64::from_le_bytes(read(uc, a, 8)?.try_into().unwrap()))
}
fn w32(uc: &mut Uc<'_>, a: u64, v: u32) -> Result<(), String> { write(uc, a, &v.to_le_bytes()) }
fn random(n: usize) -> Result<Vec<u8>, String> {
    let mut data = vec![0; n];
    getrandom::getrandom(&mut data).map_err(|e| e.to_string())?;
    Ok(data)
}

impl Engine {
    pub fn register_platform_services(&mut self) -> Result<(), Error> {
        for (names, handler) in super::platform_table::SERVICES {
            for name in *names {
                self.add_function(name, Handler::Platform(PlatformHandler::Named(handler)))?;
            }
        }
        self.state_mut().errno = self.add_data("guest.errno", &[0; 8])?;
        self.add_data("___stack_chk_guard", &[0xa5, 0x71, 0x3c, 0xd9, 0x86, 0x42, 0xef, 0x10])?;
        for name in ["_NDR_record", "_kCFAllocatorDefault", "_kCFAllocatorNull", "_kDADiskDescriptionVolumeUUIDKey", "_kIOMasterPortDefault"] {
            self.add_data(name, &[0; 8])?;
        }
        for (name, value) in [("_kCFBooleanFalse", FAKE), ("_kCFBooleanTrue", FAKE), ("__xpc_type_dictionary", 0xffff100000000001), ("__xpc_type_error", 0xffff100000000002), ("__xpc_error_connection_invalid", 0xffff100000000003)] {
            self.add_data(name, &value.to_le_bytes())?;
        }
        self.add_function("callback.complete", Handler::Platform(PlatformHandler::Named("callbackComplete")))?;
        Ok(())
    }
    pub fn allocate(&mut self, n: u64) -> Result<u64, Error> {
        let mut st = std::mem::take(self.uc.get_data_mut());
        let result = st.allocate(&mut self.uc, n).map_err(Error::Emulation);
        *self.uc.get_data_mut() = st;
        result
    }
}

impl SapState {
    pub fn new_xpc_object(&mut self, data: Option<Vec<u8>>) -> u64 {
        self.xpc_next_object += 1;
        self.xpc_objects.insert(self.xpc_next_object, XpcObject { has_data: data.is_some(), data: data.unwrap_or_default(), data_address: 0 });
        self.xpc_next_object
    }
    fn function(&mut self, uc: &mut Uc<'_>, name: &str, handler: &'static str) -> Result<u64, String> {
        if let Some(a) = self.symbols.get(name) { return Ok(*a); }
        let a = self.code_cursor;
        if a + SHIM_SLOT > SHIM_BASE + SHIM_CODE_SIZE { return Err("service code area full".into()); }
        write(uc, a, &0xd65f03c0u32.to_le_bytes())?;
        self.code_cursor += SHIM_SLOT;
        self.handlers.insert(a, Handler::Platform(PlatformHandler::Named(handler)));
        self.symbols.insert(name.into(), a);
        Ok(a)
    }
    fn data(&mut self, uc: &mut Uc<'_>, name: &str, data: &[u8]) -> Result<u64, String> {
        if let Some(a) = self.symbols.get(name) { return Ok(*a); }
        let a = align(self.data_cursor, 8);
        if a + data.len() as u64 > SHIM_BASE + SHIM_SIZE { return Err("service data area full".into()); }
        write(uc, a, data)?;
        self.data_cursor = a + data.len().max(8) as u64;
        self.symbols.insert(name.into(), a);
        Ok(a)
    }
    fn callback(&mut self, uc: &mut Uc<'_>, entry: u64) -> Result<(), String> {
        self.callback_returns.push(uc.reg_read(RegisterARM64::X30).map_err(ue)?);
        uc.reg_write(RegisterARM64::X30, self.symbols["callback.complete"]).map_err(ue)?;
        uc.reg_write(RegisterARM64::PC, entry).map_err(ue)
    }
    fn descriptor(&mut self, uc: &mut Uc<'_>, buffer: u64, capacity: u64) -> Result<u64, String> {
        if self.buffer_vtable == 0 {
            let unhandled = self.function(uc, "$buffer.unhandled", "bufferUnhandled")?;
            let mut table = unhandled.to_le_bytes().repeat(0x1000 / 8);
            for (offset, handler) in [(0x28,"returnZero"),(0xc8,"bufferRead"),(0xd0,"bufferWrite"),(0xd8,"bufferPrepare"),(0xe0,"returnZero"),(0x148,"bufferAddress"),(0x218,"bufferPrepare"),(0x220,"returnZero"),(0x308,"bufferAddress")] {
                let a = self.function(uc, &format!("$buffer.{handler}"), handler)?;
                table[offset..offset+8].copy_from_slice(&a.to_le_bytes());
            }
            self.buffer_vtable = self.data(uc, "kernel.iobuffer.vtable", &table)?;
        }
        let a = self.allocate(uc, 24)?;
        write_u64(uc, a, self.buffer_vtable)?;
        write_u64(uc, a+8, buffer)?;
        write_u64(uc, a+16, capacity)?;
        Ok(a)
    }
    pub(super) fn dispatch_platform(&mut self, uc: &mut Uc<'_>, name: &str) -> Result<(), String> {
        // Snapshot arguments before changing X0. Stack arguments follow Darwin arm64 ABI.
        let a: Vec<u64> = (0..9).map(|i| arg(uc, i)).collect();
        let result = match name {
            "returnZero" => 0,
            "returnOne" => 1,
            "returnTwo" => 2,
            "returnThree" => 3,
            "returnFakeHandle" | "returnMinusOne" => FAKE,
            "returnUnchanged" => return Ok(()),
            "abort" => return Err("guest aborted".into()),
            "errorPointer" => self.errno,
            "kqueue" => 6,
            "notifyRegisterCheck" | "notifyCheck" => { if a[1] != 0 { w32(uc,a[1],u32::from(name == "notifyRegisterCheck"))?; } 0 },
            "notifyGetState" => { if a[1] != 0 { write_u64(uc,a[1],0)?; } 0 },
            "cfRunLoopRun" => { if self.pause_run_loop { uc.emu_stop().map_err(ue)?; } 0 },
            "cfMachPortCreateWithPort" => {
                self.mach_port_callback=a[2]; self.mach_port_context=a[3];
                if a[3] != 0 { self.mach_port_info=u64_at(uc,a[3]+8)?; }
                if a[4] != 0 { write(uc,a[4],&[0])?; } FAKE
            },
            "cfStringCreate" => match read_cstring(uc,a[1]).as_str() { "IOPlatformSerialNumber" | "IOPlatformUUID" | "board-id" => FAKE, _ => 0 },
            "cfStringCreateNoCopy" => a[1],
            "cfStringGetCString" => {
                let value = if a[0] != 0 && a[0] != FAKE { read_cstring(uc,a[0]) } else { String::new() };
                let mut bytes = value.into_bytes(); bytes.push(0);
                if a[1] == 0 || (bytes.len() as u64) > a[2] { 0 } else { write(uc,a[1],&bytes)?; 1 }
            },
            "cfNumberGetValue" => { if a[2] != 0 { w32(uc,a[2],3184554750)?; } 1 },
            "ioIteratorNext" => { self.iterator = self.iterator.wrapping_add(1); (self.iterator % 2) as u64 },
            "ioMainPort" | "ioServiceOpen" | "ioRegistryEntryGetParentEntry" | "ioServiceGetMatchingServices" | "bootstrapCheckIn" | "bootstrapLookUp" => {
                let (index,value) = match name { "ioMainPort" => (1,1), "ioServiceOpen" => (3,7), "bootstrapCheckIn" => (2,1), "bootstrapLookUp" => (2,0), _ => (2,u32::MAX) };
                if name == "ioServiceGetMatchingServices" { self.iterator=0; }
                if a[index] != 0 { w32(uc,a[index],value)?; }
                if name == "bootstrapLookUp" { 5 } else { 0 }
            },
            "compareAndSwap32" => {
                if read_u32(uc,a[2])? != a[0] as u32 { 0 } else { w32(uc,a[2],a[1] as u32)?; 1 }
            },
            "arc4random" | "random31" | "arc4randomUniform" => {
                let upper = if name == "arc4randomUniform" { a[0] as u32 as u64 } else { 1u64 << 32 };
                if upper < 2 { 0 } else {
                    let limit = (1u64 << 32) - (1u64 << 32) % upper;
                    loop {
                        let value = u32::from_le_bytes(random(4)?.try_into().unwrap()) as u64;
                        if value < limit { break if name == "random31" { value & 0x7fffffff } else { value % upper }; }
                    }
                }
            },
            "readRandom" => { let data=random(checked_size(a[1])?)?; write(uc,a[0],&data)?; 0 },
            "auditTokenToAU32" => { for (i,v) in [0,0,0,0,0,123,100000,1].iter().enumerate() { if a[i+1] != 0 { w32(uc,a[i+1],*v)?; } } 0 },
            "basename" => {
                let path=read_cstring(uc,a[0]); let path=path.trim_end_matches('/');
                a[0] + path.rfind('/').map(|i|i as u64+1).unwrap_or(0)
            },
            "dlopen" => if read_cstring(uc,a[0]) == "/System/Library/PrivateFrameworks/CoreFP.framework/CoreFP" { FAKE } else { 0 },
            "dlsym" => self.core_exports.get(&format!("_{}",read_cstring(uc,a[1]))).copied().unwrap_or(0),
            "gethostuuid" => { if self.host_uuid == [0;16] { return Err("host UUID unavailable".into()); } if a[0]!=0 { write(uc,a[0],&self.host_uuid)?; } 0 },
            "gettimeofday" | "clockGetCalendarMicrotime" | "currentTime" => {
                let now=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e|e.to_string())?;
                match name {
                    "gettimeofday" => {
                        if a[0]!=0 { let mut b=[0;16]; b[..8].copy_from_slice(&now.as_secs().to_le_bytes()); b[8..12].copy_from_slice(&now.subsec_micros().to_le_bytes()); write(uc,a[0],&b)?; }
                        if a[1]!=0 { write_u64(uc,a[1],0)?; } 0
                    },
                    "clockGetCalendarMicrotime" => { w32(uc,a[0],now.as_secs() as u32)?; w32(uc,a[1],now.subsec_micros())?; 0 },
                    _ => { if a[0]!=0 { write_u64(uc,a[0],now.as_secs())?; } now.as_secs() }
                }
            },
            "objcMsgSend" => if read_cstring(uc,a[1]) == "objectForKey:" { FAKE } else { 0 },
            "open" => {
                let path=read_cstring(uc,a[0]);
                match path.as_str() {
                    "/var/db" | "/var/setup" => 4,
                    ADI_PATH => {
                        if !self.adi_files.contains_key(&path) && a[1]&0x200 == 0 { FAKE } else {
                            self.adi_files.entry(path.clone()).or_default(); self.adi_path=path; self.adi_offset=0; 5
                        }
                    },
                    "./../CoreFP.icxs" => { self.icxs_offset=0; 3 },
                    _ => FAKE
                }
            },
            "lstat" => {
                let path=read_cstring(uc,a[0]);
                if self.adi_files.contains_key(&path) { write(uc,a[1]+4,&[0x80,0x81])?; 0 }
                else if ["/var/db/fpsd/adi","/var/db","/var/setup"].contains(&path.as_str()) { write(uc,a[1]+4,&[0xed,0x41])?; 0 }
                else { FAKE }
            },
            "fstat" => {
                if a[0]!=5 { FAKE } else {
                    write(uc,a[1],&[0;144])?; write(uc,a[1]+4,&[0x80,0x81])?;
                    write_u64(uc,a[1]+96,self.adi_files.get(&self.adi_path).map(Vec::len).unwrap_or(0) as u64)?; 0
                }
            },
            "ftruncate" => {
                if a[0]!=5 || a[1]>1<<20 { FAKE } else {
                    self.adi_files.entry(self.adi_path.clone()).or_default().resize(a[1] as usize,0);
                    self.adi_offset=self.adi_offset.min(a[1] as usize); 0
                }
            },
            "read" => {
                let size=checked_size(a[2])?;
                let (data,offset)=match a[0] {
                    3 => (&self.icxs,self.icxs_offset),
                    5 => (self.adi_files.get(&self.adi_path).ok_or("ADI file not open")?, self.adi_offset),
                    _ => { set_result(uc,FAKE); return Ok(()); }
                };
                let size=size.min(data.len().saturating_sub(offset));
                write(uc,a[1],&data[offset..offset+size])?;
                if a[0]==3 { self.icxs_offset+=size; } else { self.adi_offset+=size; } size as u64
            },
            "write" => {
                if a[0]!=5 { FAKE } else {
                    let size=checked_size(a[2])?;
                    let end=self.adi_offset.checked_add(size).ok_or("ADI file size overflow")?;
                    if end>1<<20 { return Err("ADI state exceeds limit".into()); }
                    let bytes=read(uc,a[1],a[2])?;
                    let data=self.adi_files.entry(self.adi_path.clone()).or_default();
                    data.resize(data.len().max(end),0); data[self.adi_offset..end].copy_from_slice(&bytes); self.adi_offset=end; size as u64
                }
            },
            "unlink" => { let path=read_cstring(uc,a[0]); if path==ADI_PATH { self.adi_files.remove(&path); self.adi_offset=0; 0 } else { FAKE } },
            "procPIDPath" => {
                let path=b"/System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Resources/commerce\0";
                if a[1]==0 || a[2]<path.len() as u64 { FAKE } else { write(uc,a[1],path)?; path.len() as u64-1 }
            },
            "sysconf" => match a[0] {29=>PAGE,57|58=>1,200=>HEAP_SIZE/PAGE,_=>FAKE},
            "sysctlbyname" => {
                let value=match read_cstring(uc,a[0]).as_str() {
                    "kern.monotonicclock"|"hw.ncpu"|"hw.logicalcpu"|"hw.physicalcpu"|"hw.optional.arm64"=>1u32.to_le_bytes().to_vec(),
                    "hw.memsize"=>(8u64<<30).to_le_bytes().to_vec(), "hw.machine"=>b"arm64\0".to_vec(),"hw.model"=>b"MacBookPro13,3\0".to_vec(),"kern.osversion"=>b"16G29\0".to_vec(),
                    _=>{set_result(uc,FAKE);return Ok(());}
                };
                if a[2]!=0 {
                    if a[1]!=0 && u64_at(uc,a[2])?<value.len() as u64 {set_result(uc,FAKE);return Ok(());}
                    if a[1]!=0 {write(uc,a[1],&value)?;} write_u64(uc,a[2],value.len() as u64)?;
                } 0
            },
            "pthreadOnce" => {
                let value=u64_at(uc,a[0])?;
                if value!=0 && value!=0x4f4e4345 { write_u64(uc,a[0],0x4f4e4345)?; return self.callback(uc,a[1]); } 0
            },
            "dispatchOnce" => {
                if u64_at(uc,a[0])?!=FAKE { write_u64(uc,a[0],FAKE)?; let entry=u64_at(uc,a[1]+16)?; set_result(uc,a[1]); return self.callback(uc,entry); } 0
            },
            "callbackComplete" => {
                let address=self.callback_returns.pop().ok_or("callback completed without return address")?;
                uc.reg_write(RegisterARM64::X30,address).map_err(ue)?; 0
            },
            "xpcConnectionCreateMachService"|"xpcDictionaryCreateEmpty"|"xpcDictionaryCreateReply" => self.new_xpc_object(None),
            "xpcConnectionSendMessageWithReplySync" => self.new_xpc_object(if self.xpc_sync_reply.is_empty(){None}else{Some(self.xpc_sync_reply.clone())}),
            "xpcConnectionSetEventHandler" => {
                let data=read(uc,a[1],64)?; let address=self.allocate(uc,64)?; write(uc,address,&data)?; self.xpc_event_handler=address; 0
            },
            "xpcDictionaryGetAuditToken" => {
                if a[1]!=0 { let mut b=[0;32]; b[..4].copy_from_slice(&u32::MAX.to_le_bytes()); b[20..24].copy_from_slice(&123u32.to_le_bytes()); b[24..28].copy_from_slice(&100000u32.to_le_bytes()); b[28..].copy_from_slice(&1u32.to_le_bytes()); write(uc,a[1],&b)?; } 0
            },
            "xpcDictionarySetData" => {
                if a[3]>1<<20 { return Err("XPC data exceeds limit".into()); }
                self.xpc_data=read(uc,a[2],a[3])?;
                if let Some(object)=self.xpc_objects.get_mut(&a[0]) { object.data=self.xpc_data.clone(); object.has_data=true; object.data_address=0; } 0
            },
            "xpcDictionaryGetData" => {
                let (data,mut address)=match self.xpc_objects.get(&a[0]) {
                    Some(object) if object.has_data=>(object.data.clone(),object.data_address),
                    _=>{ if a[2]!=0 {write_u64(uc,a[2],0)?;} set_result(uc,0); return Ok(()); }
                };
                if address==0 { address=self.allocate(uc,data.len().max(1) as u64)?; write(uc,address,&data)?; self.xpc_objects.get_mut(&a[0]).unwrap().data_address=address; }
                if a[2]!=0 {write_u64(uc,a[2],data.len() as u64)?;} address
            },
            "xpcDictionarySendReply" => { if let Some(object)=self.xpc_objects.get(&a[0]) {self.xpc_reply=object.data.clone();} self.xpc_replied=true; 0 },
            "xpcGetType" => if self.xpc_objects.contains_key(&a[0]) {self.symbols["__xpc_type_dictionary"]}else{0},
            "machMsg" => { if a[2]>0 && a[2]<=1<<20 {self.mach_message_reply=read(uc,a[0],a[2])?;} 0 },
            "machMsgRPCFromKernel" => {
                if a[1]==0 || a[1]>1<<20 || a[2]>1<<20 {return Err("kernel Mach RPC size invalid".into());}
                let request=read(uc,a[0],a[1])?;
                let handler=self.mach_rpc_handler.as_mut().ok_or("kernel Mach RPC handler unavailable")?;
                let reply=handler(&request,a[2] as usize)?;
                if reply.is_empty() || reply.len()>a[2] as usize {return Err("kernel Mach RPC reply invalid".into());}
                write(uc,a[0],&reply)?; 0
            },
            "ioConnectCallStructMethod" => {
                let output_size=if a[5]!=0 {u64_at(uc,a[5])?}else{0};
                if a[3]>1<<20 || output_size>1<<20 {return Err("FairPlay IOKit buffer exceeds limit".into());}
                let input=read(uc,a[2],a[3])?;
                let mut indirect_address=0;
                let indirect=if a[1]==26 && input.len()==16 {
                    indirect_address=u64::from_le_bytes(input[..8].try_into().unwrap());
                    let n=u64::from_le_bytes(input[8..].try_into().unwrap());
                    if n==0 || n>1<<20 {return Err("FairPlay indirect buffer invalid".into());}
                    read(uc,indirect_address,n)?
                }else{vec![]};
                let handler=self.fairplay_handler.as_mut().ok_or("FairPlay IOKit handler unavailable")?;
                let (mut output,mut updated,mut status)=handler(&input,&indirect,output_size as usize)?;
                // Exact upstream software IOAES fallback, not a synthetic network response.
                if status!=0 && a[1]==26 && indirect.len()>=16 && input.len()==output_size as usize {
                    updated=indirect.clone(); let n=updated.len()-16; let digest=Sha256::digest(&updated[..n]); updated[n..].copy_from_slice(&digest[..16]); output=input.clone(); status=0;
                }
                if !updated.is_empty() {write(uc,indirect_address,&updated)?; if output.len()>=8 {output[..8].copy_from_slice(&indirect_address.to_le_bytes());}}
                if output.len()>output_size as usize {return Err("FairPlay output exceeds capacity".into());}
                write(uc,a[4],&output)?; if a[5]!=0 {write_u64(uc,a[5],output.len() as u64)?;} status as u32 as u64
            },
            "waitForKernelService" => {
                if read_cstring(uc,a[0])!="IOAESAccelerator" {0} else if self.aes_service!=0 {self.aes_service} else {
                    let unhandled=self.function(uc,"$aes.unhandled","returnZero")?;
                    let retain=self.function(uc,"$aes.retain","returnUnchanged")?;
                    let perform=self.function(uc,"$aes.perform","ioAESPerform")?;
                    let mut table=unhandled.to_le_bytes().repeat(0x900/8);
                    for (offset,value) in [(0x20,retain),(0x550,perform),(0x890,perform)] {table[offset..offset+8].copy_from_slice(&value.to_le_bytes());}
                    self.aes_vtable=self.data(uc,"kernel.ioaes.vtable",&table)?;
                    self.aes_service=self.allocate(uc,16)?; write_u64(uc,self.aes_service,self.aes_vtable)?; self.aes_service
                }
            },
            "newKernelBufferDescriptor"|"newKernelBufferDescriptorAt" => {
                let (buffer,capacity)=if name=="newKernelBufferDescriptor" {
                    if a[2]==0 || a[2]>MAX_GUEST_TRANSFER {set_result(uc,0);return Ok(());}
                    let buffer=self.allocate_aligned(uc,a[2],16)?; write(uc,buffer,&vec![0;a[2] as usize])?; (buffer,a[2])
                }else{(a[0],a[1])};
                if buffer==0 || capacity==0 || capacity>MAX_GUEST_TRANSFER {0}else{self.descriptor(uc,buffer,capacity)?}
            },
            "bufferUnhandled"=>return Err(format!("unsupported IOMemoryDescriptor method from {:#x}",uc.reg_read(RegisterARM64::X30).map_err(ue)?)),
            "bufferPrepare"=>{let buffer=u64_at(uc,a[0]+8)?;let n=u64_at(uc,a[0]+16)?;if buffer==0||n==0||n>MAX_GUEST_TRANSFER{3}else{0}},
            "bufferAddress"=>u64_at(uc,a[0]+8)?,
            "bufferRead"|"bufferWrite"=>{
                let buffer=u64_at(uc,a[0]+8)?; let n=u64_at(uc,a[0]+16)?;
                if a[1]>n || a[3]>n-a[1] || a[3]>MAX_GUEST_TRANSFER {0}else{
                    let (source,target)=if name=="bufferWrite"{(a[2],buffer+a[1])}else{(buffer+a[1],a[2])};
                    let data=read(uc,source,a[3])?;write(uc,target,&data)?;a[3]
                }
            },
            "ioAESPerform"=>{
                let n=a[3];
                if n==0||n>MAX_GUEST_TRANSFER||n%16!=0 {3}else{
                    let source=u64_at(uc,a[1]+8)?;let source_size=u64_at(uc,a[1]+16)?;
                    let target=u64_at(uc,a[2]+8)?;let target_size=u64_at(uc,a[2]+16)?;
                    if a[7]>source_size||n>source_size-a[7]||a[8]>target_size||n>target_size-a[8] {3}else{
                        let input=read(uc,source+a[7],n)?;let iv=read(uc,a[4],16)?;let key=read(uc,a[6],40)?;
                        let (out,iv)=emulate_ioaes(&input,&iv,a[5] as u32,&key)?;
                        write(uc,target+a[8],&out)?;write(uc,a[4],&iv)?;0
                    }
                }
            },
            _ => return Err(format!("unknown platform service {name}")),
        };
        set_result(uc,result);
        Ok(())
    }
}

pub fn emulate_ioaes(source: &[u8], iv: &[u8], operation: u32, key: &[u8]) -> Result<(Vec<u8>, Vec<u8>), String> {
    if source.is_empty() || source.len()%16!=0 || iv.len()!=16 || key.len()!=40 {return Err("invalid IOAES parameters".into());}
    if u32::from_le_bytes(key[36..40].try_into().unwrap())!=0x89c {return Err("unsupported IOAES key handle".into());}
    if operation>1 {return Err("unsupported IOAES operation".into());}
    let cipher=Aes128::new(GenericArray::from_slice(&[0;16]));
    let mut chain=iv.to_vec();let mut output=Vec::with_capacity(source.len());
    for input in source.chunks_exact(16) {
        let mut block=GenericArray::clone_from_slice(input);
        if operation==0 {
            for i in 0..16 {block[i]^=chain[i];} cipher.encrypt_block(&mut block); chain.copy_from_slice(&block);
        }else{
            cipher.decrypt_block(&mut block);for i in 0..16 {block[i]^=chain[i];}chain.copy_from_slice(input);
        }
        output.extend_from_slice(&block);
    }
    Ok((output,chain))
}
