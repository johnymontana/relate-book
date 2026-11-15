/// <reference lib="webworker" />
// WebLLM's engine, off the page thread: model download, WebGPU compilation and
// token generation all happen here.

import { WebWorkerMLCEngineHandler } from '@mlc-ai/web-llm';

const handler = new WebWorkerMLCEngineHandler();
self.onmessage = (event: MessageEvent) => handler.onmessage(event);
