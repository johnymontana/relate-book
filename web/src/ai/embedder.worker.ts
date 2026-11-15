/// <reference lib="webworker" />
// The embedding model: all-MiniLM-L6-v2 (384 dimensions) through
// transformers.js, on WebGPU when the browser has it and on WASM otherwise.
//
// Mean pooling over the attention mask and L2 normalisation, truncated at
// 256 tokens: the same recipe the iPhone app's Core ML model uses, so both
// apps embed a book the same way.

import { AutoModel, AutoTokenizer, type PreTrainedModel, type PreTrainedTokenizer, type Tensor } from '@huggingface/transformers';

export type EmbedderRequest = { id: number; type: 'load'; model: string; device: 'webgpu' | 'wasm' } | { id: number; type: 'embed'; texts: string[] };

export type EmbedderResponse =
  | { id: number; type: 'progress'; file: string; loaded: number; total: number }
  | { id: number; type: 'loaded'; device: 'webgpu' | 'wasm'; dtype: string }
  | { id: number; type: 'embedded'; vectors: number[][] }
  | { id: number; type: 'error'; message: string };

const MAX_TOKENS = 256;

let tokenizer: PreTrainedTokenizer | null = null;
let model: PreTrainedModel | null = null;

const post = (message: EmbedderResponse) => self.postMessage(message);

async function load(id: number, name: string, device: 'webgpu' | 'wasm') {
  const progress_callback = (info: { status: string; file?: string; loaded?: number; total?: number }) => {
    if (info.status === 'progress' && info.file && info.total) post({ id, type: 'progress', file: info.file, loaded: info.loaded ?? 0, total: info.total });
  };
  tokenizer = await AutoTokenizer.from_pretrained(name, { progress_callback });
  // Full precision on the GPU; the 8-bit model (a quarter of the download) on WASM.
  const dtype = device === 'webgpu' ? 'fp32' : 'q8';
  model = await AutoModel.from_pretrained(name, { device, dtype, progress_callback });
  return dtype;
}

async function embed(texts: string[]): Promise<number[][]> {
  if (!tokenizer || !model) throw new Error('the embedding model is not loaded');
  const inputs = tokenizer(texts, { padding: true, truncation: true, max_length: MAX_TOKENS });
  const output = (await model(inputs)) as { last_hidden_state: Tensor };
  const hidden = output.last_hidden_state;
  const [batch, length, width] = hidden.dims as [number, number, number];
  const values = hidden.data as Float32Array;
  const mask = inputs.attention_mask.data as BigInt64Array;
  const vectors: number[][] = [];
  for (let b = 0; b < batch; b++) {
    const sum = new Float64Array(width);
    let count = 0;
    for (let t = 0; t < length; t++) {
      if (mask[b * length + t] === 0n) continue;
      count++;
      const offset = (b * length + t) * width;
      for (let d = 0; d < width; d++) sum[d] += values[offset + d];
    }
    let norm = 0;
    for (let d = 0; d < width; d++) {
      sum[d] /= Math.max(1, count);
      norm += sum[d] * sum[d];
    }
    norm = Math.sqrt(norm) || 1;
    vectors.push(Array.from(sum, (x) => x / norm));
  }
  return vectors;
}

let queue: Promise<void> = Promise.resolve();

self.onmessage = (event: MessageEvent<EmbedderRequest>) => {
  const msg = event.data;
  queue = queue.then(async () => {
    try {
      if (msg.type === 'load') {
        let device = msg.device;
        let dtype: string;
        try {
          dtype = await load(msg.id, msg.model, device);
        } catch (err) {
          if (device !== 'webgpu') throw err;
          // A GPU that cannot run the model (or a blocked adapter) falls back to WASM.
          device = 'wasm';
          dtype = await load(msg.id, msg.model, device);
        }
        post({ id: msg.id, type: 'loaded', device, dtype });
      } else {
        post({ id: msg.id, type: 'embedded', vectors: await embed(msg.texts) });
      }
    } catch (err) {
      post({ id: msg.id, type: 'error', message: err instanceof Error ? err.message : String(err) });
    }
  });
};
