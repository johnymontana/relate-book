// The language models offered in the app. All are prebuilt WebLLM models
// (MLC-compiled, 4-bit quantized, fetched from Hugging Face on first use and
// kept in the browser's Cache Storage). Sizes are WebLLM's own VRAM figures.

export interface ModelChoice {
  id: string;
  name: string;
  /** Approximate GPU memory needed, in GB. */
  vramGb: number;
  note: string;
  /** The licence on the original model's Hugging Face card (2026-11-14). */
  licence: string;
  /** Reasoning models are run with thinking turned off: the steps here are short and latency matters. */
  thinking?: boolean;
}

export const MODELS: ModelChoice[] = [
  {
    id: 'Qwen2.5-Coder-3B-Instruct-q4f16_1-MLC',
    name: 'Qwen2.5 Coder 3B',
    vramGb: 2.5,
    note: 'The default: the best chat answers of the three sizes measured, and the model the prompts were tuned with.',
    licence: 'Qwen Research Licence (research use)',
  },
  {
    id: 'Qwen2.5-Coder-1.5B-Instruct-q4f16_1-MLC',
    name: 'Qwen2.5 Coder 1.5B',
    vramGb: 1.6,
    note: 'As good at Cypher as the 3B in testing and about twice as fast, but it invents facts in chat answers.',
    licence: 'Apache-2.0',
  },
  {
    id: 'Qwen2.5-Coder-7B-Instruct-q4f16_1-MLC',
    name: 'Qwen2.5 Coder 7B',
    vramGb: 5.1,
    note: 'No better at Cypher than the smaller two in testing, and slower. Needs a GPU with 6 GB or more to spare.',
    licence: 'Apache-2.0',
  },
  {
    id: 'Llama-3.2-3B-Instruct-q4f16_1-MLC',
    name: 'Llama 3.2 3B',
    vramGb: 2.3,
    note: 'A general chat model. Not evaluated here.',
    licence: 'Llama 3.2 Community License',
  },
  {
    id: 'Phi-4-mini-instruct-q4f16_1-MLC',
    name: 'Phi-4 mini',
    vramGb: 3.4,
    note: 'A general model. Not evaluated here.',
    licence: 'MIT',
  },
  {
    id: 'Qwen3-4B-q4f16_1-MLC',
    name: 'Qwen3 4B',
    vramGb: 3.4,
    note: 'A newer general model, run with thinking off. Not evaluated here.',
    licence: 'Apache-2.0',
    thinking: true,
  },
];

export const DEFAULT_MODEL_ID = MODELS[0].id;

export function modelChoice(id: string): ModelChoice | undefined {
  return MODELS.find((m) => m.id === id);
}
