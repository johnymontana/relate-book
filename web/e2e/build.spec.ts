import { expect, test } from '@playwright/test';

// The production build, served under a sub-path. What differs from the dev
// server: hashed asset names, the engine worker as a separate bundle, the
// .wasm file fetched by URL, and the sample dataset resolved relative to the
// page (the worker must not resolve it against its own script).

test('the built app starts, loads the sample and queries it', async ({ page }) => {
  const problems: string[] = [];
  page.on('pageerror', (err) => problems.push(err.message));
  page.on('console', (msg) => {
    if (msg.type() === 'error') problems.push(msg.text());
  });
  page.on('response', (response) => {
    if (response.status() >= 400) problems.push(`${response.status()} ${response.url()}`);
  });

  await page.goto('./');
  await expect(page.getByTestId('hero-books')).toHaveText('6');
  await expect(page.getByTestId('dataset-chip')).toContainText('Book List');

  await page.getByTestId('tab-query').click();
  await page.getByTestId('cypher-editor').fill('MATCH (b:Book)-[:WRITTEN_BY]->(a:Author) RETURN a.name AS author, b.title AS title ORDER BY title LIMIT 3');
  await page.getByTestId('run-button').click();
  await expect(page.getByTestId('result-table')).toContainText('Tracy Kidder');

  await page.getByTestId('tab-graph').click();
  await expect(page.getByTestId('graph-counts')).toContainText('14 nodes · 8 relationships');
  await expect(page.getByTestId('graph').locator('canvas').first()).toBeVisible();

  // The developer handle and the stub models are not part of a build.
  expect(await page.evaluate(() => '__relateBooks' in window)).toBe(false);
  expect(problems).toEqual([]);
});

test('the built app ignores ?stub-ai', async ({ page }) => {
  await page.goto('./?stub-ai#chat');
  await page.getByTestId('chat-load-model').click();
  // The real model list is offered; nothing is loaded by a URL flag.
  await expect(page.getByTestId('models-drawer')).toContainText('Qwen2.5 Coder 3B');
  await expect(page.getByTestId('models-drawer')).not.toContainText('stub-ai is on');
});
