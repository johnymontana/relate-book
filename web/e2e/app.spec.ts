import { expect, test, type Page } from '@playwright/test';
import { fileURLToPath } from 'node:url';

// `dataset=sample` keeps a local export out of the way; `stub-ai` swaps the
// models for deterministic stand-ins. Each test gets a fresh browser context,
// so the OPFS store starts empty.
const HOME = '/?dataset=sample&stub-ai';
const SAMPLE = fileURLToPath(new URL('../public/data/sample.json', import.meta.url));

async function open(page: Page, hash = '') {
  const problems: string[] = [];
  page.on('pageerror', (err) => problems.push(err.message));
  page.on('console', (msg) => {
    if (msg.type() === 'error') problems.push(msg.text());
  });
  await page.goto(`${HOME}${hash}`);
  await expect(page.getByTestId('dataset-chip')).toContainText('Book List');
  return problems;
}

/** Optionally save a screenshot for the README (SCREENSHOT_DIR=/abs/dir npm run e2e). */
async function shot(page: Page, name: string) {
  const dir = process.env.SCREENSHOT_DIR;
  if (!dir) return;
  // Let the graph layout settle and the view fit before the picture.
  await page.waitForTimeout(2000);
  await page.screenshot({ path: `${dir}/${name}.png` });
}

test('loads the sample into Relate WASM and charts it', async ({ page }) => {
  const problems = await open(page);
  await expect(page.getByTestId('hero-books')).toHaveText('6');
  await expect(page.getByTestId('dataset-chip')).toContainText(/OPFS|memory/);
  for (const id of ['decades', 'ratings', 'authors', 'subjects', 'places', 'formats', 'pages', 'awards']) {
    await expect(page.getByTestId(`chart-${id}`)).toBeVisible();
  }
  // Every value is reachable without hovering: bars carry an accessible name, and each chart has a table view.
  await expect(page.getByTestId('chart-authors').getByRole('button', { name: 'Andy Weir: 1 books' })).toBeVisible();
  await page.getByTestId('chart-formats').getByRole('button', { name: 'Table' }).click();
  await expect(page.getByTestId('chart-formats').getByRole('row', { name: /Kindle Edition 4/ })).toBeVisible();
  // The Cypher behind a chart is one click away.
  await page.getByTestId('chart-decades').getByText('Cypher').click();
  await expect(page.getByTestId('chart-decades').getByTestId('cypher-code')).toContainText('MATCH (b:Book)');
  await shot(page, 'overview');
  expect(problems).toEqual([]);
});

test('a chart bar opens the books behind it', async ({ page }) => {
  await open(page);
  await page.getByTestId('chart-authors').getByRole('button', { name: /^Andy Weir:/ }).click();
  await expect(page.getByTestId('library-status')).toHaveText('1 book · Author: Andy Weir');
  await expect(page.getByTestId('book-row')).toHaveCount(1);
  await expect(page.getByTestId('book-row')).toContainText('Project Hail Mary');
  await page.getByRole('button', { name: /Clear filter/ }).click();
  await expect(page.getByTestId('book-row')).toHaveCount(6);
});

test('library: sort, open a book, follow a tag', async ({ page }) => {
  await open(page, '#library');
  await expect(page.getByTestId('book-row')).toHaveCount(6);
  await expect(page.getByTestId('book-row').first()).toContainText('A Truck Full of Money');
  await page.getByLabel('Sort books').selectOption('newest');
  await expect(page.getByTestId('book-row').first()).toContainText('Project Hail Mary');

  await page.getByTestId('book-row').filter({ hasText: 'The Left Hand of Darkness' }).click();
  const panel = page.getByTestId('book-panel');
  await expect(panel.getByRole('heading', { name: 'The Left Hand of Darkness' })).toBeVisible();
  await expect(panel.getByRole('button', { name: 'Ursula K. Le Guin' })).toBeVisible();
  await expect(panel.getByRole('button', { name: 'Hainish Cycle #4' })).toBeVisible();
  await shot(page, 'library-book');
  await panel.getByRole('button', { name: 'Gethen', exact: true }).click();
  await expect(page.getByTestId('library-status')).toHaveText('1 book · Place: Gethen');
});

test('library: keyword search, then semantic search once the embedding model is on', async ({ page }) => {
  await open(page, '#library');
  await page.getByTestId('library-search').fill('murder mystery');
  await expect(page.getByTestId('library-status')).toContainText('fulltext only');
  await expect(page.getByTestId('book-row')).toHaveCount(1);
  await expect(page.getByTestId('book-row')).toContainText('The Curious Incident');

  await page.getByTestId('enable-semantic').click();
  await expect(page.getByTestId('ai-chip')).toHaveText('Embeddings on');
  await page.getByTestId('library-search').fill('colonization of Mars');
  await expect(page.getByTestId('library-status')).toContainText('vector index + fulltext, fused');
  await expect(page.getByTestId('book-row').first()).toContainText('Red Mars');
  await expect(page.getByTestId('book-row').first()).toContainText('meaning + keywords');

  // The vectors are in the graph, so "more like this" has neighbours.
  await page.getByTestId('book-row').first().click();
  await expect(page.getByTestId('book-panel').locator('.similar-row')).toHaveCount(5);
});

test('graph: presets, find a node, hand-off from a book', async ({ page }) => {
  const problems = await open(page, '#graph');
  const canvas = page.getByTestId('graph').getByTestId('graph-canvas');
  await expect(page.getByTestId('graph-counts')).toContainText('14 nodes · 8 relationships');
  await expect(canvas).toHaveAttribute('data-nodes', '14');
  await expect(canvas.locator('canvas').first()).toBeVisible();

  await page.getByTestId('preset-genres').click();
  await expect(page.getByTestId('graph-counts')).toContainText('13 nodes · 12 relationships');

  await page.getByTestId('graph-find').fill('weir');
  await page.getByRole('button', { name: /Author\s*Andy Weir/ }).click();
  await expect(page.getByTestId('graph-counts')).toContainText('relationship');
  await expect(canvas).not.toHaveAttribute('data-nodes', '13');
  await shot(page, 'graph');

  await page.getByTestId('tab-library').click();
  await page.getByTestId('book-row').filter({ hasText: 'Red Mars' }).click();
  await page.getByTestId('book-panel').getByRole('button', { name: 'Show in graph' }).click();
  await expect(page.getByTestId('graph')).toBeVisible();
  await expect(page.getByTestId('graph-counts')).not.toContainText('13 nodes');
  expect(problems).toEqual([]);
});

test('query: run Cypher, see a graph, an error and a plan', async ({ page }) => {
  await open(page, '#query');
  const editor = page.getByTestId('cypher-editor');
  await editor.fill('MATCH (b:Book) RETURN b.title AS title ORDER BY title LIMIT 3');
  await page.getByTestId('run-button').click();
  await expect(page.getByTestId('result-table').getByRole('row')).toHaveCount(4);
  await expect(page.getByTestId('query-stats')).toContainText('3 rows · engine');

  await editor.fill("MATCH p = (b:Book)-[:WRITTEN_BY]->(a:Author) WHERE a.name = 'Andy Weir' RETURN p");
  await editor.press('ControlOrMeta+Enter');
  await expect(page.getByTestId('query').getByTestId('graph-canvas')).toHaveAttribute('data-nodes', '2');

  await editor.fill('MATCH (b:Book RETURN b');
  await page.getByTestId('run-button').click();
  await expect(page.getByTestId('query-error')).toContainText('syntax error');

  await editor.fill('EXPLAIN MATCH (b:Book)-[:WRITTEN_BY]->(a) RETURN a.name, count(b)');
  await page.getByTestId('run-button').click();
  await expect(page.getByRole('button', { name: 'Plan', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByText('EagerAggregation')).toBeVisible();
});

test('query: a write survives a reload (the OPFS store is durable)', async ({ page }) => {
  await open(page, '#query');
  test.skip(!(await page.getByTestId('dataset-chip').innerText()).includes('OPFS'), 'this browser fell back to the in-memory store');
  const editor = page.getByTestId('cypher-editor');
  await editor.fill("CREATE (:Subject {name: 'e2e marker'})");
  await page.getByTestId('run-button').click();
  await expect(page.getByTestId('query-stats')).toContainText('nodes created 1');

  await page.reload();
  await expect(page.getByTestId('dataset-chip')).toContainText('OPFS');
  await page.getByTestId('cypher-editor').fill("MATCH (s:Subject {name: 'e2e marker'}) RETURN count(s) AS markers");
  await page.getByTestId('run-button').click();
  await expect(page.getByTestId('result-table')).toContainText('1');
  // And the other tabs see the write: 173 subjects in the sample, plus the marker.
  await page.getByTestId('tab-overview').click();
  await expect(page.getByTestId('overview')).toContainText('174');
});

test('ask: a question becomes Cypher, with its trace', async ({ page }) => {
  await open(page, '#query');
  await page.getByTestId('ask-load-model').click();
  await page.getByTestId('load-llm').click();
  await expect(page.getByTestId('ai-chip')).toHaveText('stub/scripted');
  await page.keyboard.press('Escape');

  await page.getByTestId('ask-input').fill('Which authors have the most books on my list?');
  await page.getByTestId('ask-button').click();
  const trace = page.getByTestId('ask-trace');
  await expect(trace).toContainText('Retrieve examples.');
  await expect(trace).toContainText('validated with EXPLAIN and run');
  await expect(page.getByTestId('cypher-editor')).toHaveValue(/MATCH \(a:Author\)<-\[:WRITTEN_BY\]-\(b:Book\)/);
  await expect(page.getByTestId('result-table')).toContainText('Ursula K. Le Guin');
  await expect(page.getByTestId('query-stats')).toContainText('6 rows');
  await shot(page, 'ask');
});

test('chat: the agent calls a tool and answers from it', async ({ page }) => {
  await open(page, '#chat');
  await page.getByTestId('chat-load-model').click();
  await page.getByTestId('load-llm').click();
  await expect(page.getByTestId('ai-chip')).toHaveText('stub/scripted');
  await page.keyboard.press('Escape');

  await page.getByTestId('chat-input').fill('Which authors have the most books on my list?');
  await page.getByTestId('chat-send').click();
  await expect(page.getByTestId('chat-step')).toHaveCount(1);
  await expect(page.getByTestId('chat-step')).toContainText('Query the graph');
  await expect(page.getByTestId('chat-answer')).toContainText('From the wishlist graph');
  await page.getByTestId('chat-step').getByText(/^Why:/).click();
  await expect(page.getByTestId('chat-step').getByTestId('result-table')).toContainText('Andy Weir');

  await page.getByTestId('chat-input').fill('books about Mars');
  await page.getByTestId('chat-input').press('Enter');
  await expect(page.getByTestId('chat-step')).toHaveCount(2);
  await expect(page.getByTestId('chat-step').nth(1)).toContainText('Search books');
  await shot(page, 'chat');
});

test('datasets: open an export from a file, and refuse a file that is not one', async ({ page }) => {
  await open(page);
  await page.getByTestId('dataset-chip').click();
  await page.getByTestId('dataset-file').setInputFiles(SAMPLE);
  await expect(page.getByTestId('hero-books')).toHaveText('6');
  await page.getByTestId('dataset-chip').click();
  await expect(page.getByTestId('dataset-menu')).toContainText('311 nodes · 344 relationships');

  await page.getByTestId('dataset-file').setInputFiles({ name: 'notes.json', mimeType: 'application/json', buffer: Buffer.from('{"hello": "world"}') });
  await page.getByTestId('dataset-chip').click();
  await expect(page.getByTestId('dataset-menu')).toContainText('not a Relate Books dataset');
  // The graph that was loaded is still there.
  await expect(page.getByTestId('hero-books')).toHaveText('6');
});
