'use strict';
// ARM64 blocks are translated to Wasm by Swift at runtime. This worker executes
// those bytes, not a Wasm build of the ARM64 interpreter. No host imports occur
// during the hot loop. WebKit owns compilation/tiering; no private JIT APIs.
const hex = v => BigInt.asUintN(64, v).toString(16).padStart(16, '0');
const capabilities = {
  wasm: typeof WebAssembly !== 'undefined',
  sharedMemory: typeof SharedArrayBuffer !== 'undefined',
  crossOriginIsolated: self.crossOriginIsolated === true,
  userAgent: navigator.userAgent
};
postMessage({kind:'ready', capabilities});
onmessage = async ({data: job}) => {
  if (job.kind !== 'run') return;
  try {
    if (!Number.isInteger(job.blocks) || job.blocks < 0 || job.blocks > 1000000000)
      throw new Error('Invalid block budget');
    const bytes = Uint8Array.from(atob(job.module), c => c.charCodeAt(0));
    const compilationStarted = performance.now();
    const module = await WebAssembly.compile(bytes);
    const compileMilliseconds = performance.now() - compilationStarted;
    const memory = new WebAssembly.Memory({initial:job.pages, maximum:job.pages});
    const instance = await WebAssembly.instantiate(module, {env:{memory}});
    const view = new DataView(memory.buffer);
    const reset = () => {
      new Uint8Array(memory.buffer).fill(0);
      for (let i=0; i<32; i++) view.setBigUint64(i*8, BigInt('0x'+job.registers[i]), true);
      view.setBigUint64(256, BigInt('0x'+job.pc), true);
      view.setBigUint64(264, 5n, true);
      for (const seed of job.memorySeeds)
        new Uint8Array(memory.buffer, 4096+seed.offset, seed.bytes.length).set(seed.bytes);
    };
    for (let i=0; i<3; i++) {
      reset(); try { instance.exports.run(Math.min(job.blocks, 10000)); } catch (_) { break; }
    }
    const times = [];
    let completedBlocks = 0, trapped = null;
    for (let i=0; i<3; i++) {
      reset();
      const start = performance.now();
      try { completedBlocks = instance.exports.run(job.blocks); }
      catch (e) { trapped = String(e); }
      times.push(performance.now()-start);
      if (trapped) break;
    }
    postMessage({kind:'result', id:job.id, report:{
      compileMilliseconds, executionMilliseconds:times,
      completedBlocks, retiredInstructions:hex(view.getBigUint64(272,true)),
      registers:Array.from({length:32},(_,i)=>hex(view.getBigUint64(i*8,true))),
      pc:hex(view.getBigUint64(256,true)), pstate:hex(view.getBigUint64(264,true)),
      ramSample:Array.from(new Uint8Array(memory.buffer,4096+job.watchAddress,16)),
      memoryBytes:memory.buffer.byteLength, capabilities, trapped,
      engine:'WebKit WebAssembly; tier controlled by WebKit'
    }});
  } catch(e) {
    postMessage({kind:'error', id:job.id, error:String(e)});
  }
};
