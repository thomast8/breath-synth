// AudioWorkletProcessor — runs on the audio render thread, not the main thread. Deliberately tiny
// and allocation-light in `process()` (a real-time constraint, not a style preference): it only
// copies each render quantum's samples into a batch buffer and posts the batch to the main thread
// every `batchFrames` samples. All the actual capture-state logic (level metering, the quiet-gap
// auto-stop heuristic, WAV encoding) lives in CaptureController on the main thread, where none of
// that matters.
//
// No imports from app code — this file is loaded standalone via `audioWorklet.addModule(url)`, in
// its own JS realm with no access to the rest of the bundle.

class RecorderProcessor extends AudioWorkletProcessor {
  private batch: Float32Array;
  private writeIndex = 0;

  constructor() {
    super();
    const batchFrames = 2048;
    this.batch = new Float32Array(batchFrames);
  }

  process(inputs: Float32Array[][]): boolean {
    const input = inputs[0]?.[0];
    if (!input) return true;

    for (let i = 0; i < input.length; i++) {
      this.batch[this.writeIndex] = input[i];
      this.writeIndex++;
      if (this.writeIndex >= this.batch.length) {
        this.port.postMessage(this.batch.slice(0));
        this.writeIndex = 0;
      }
    }
    return true;
  }
}

registerProcessor("recorder-processor", RecorderProcessor);
