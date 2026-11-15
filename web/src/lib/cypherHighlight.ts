// A small Cypher tokenizer for display. Not a parser: keywords, strings,
// numbers and comments get a class, everything else is plain text.

const KEYWORDS = new Set(
  (
    'MATCH OPTIONAL WHERE RETURN WITH ORDER BY SKIP LIMIT AS AND OR NOT XOR IN IS NULL DISTINCT UNWIND CALL YIELD UNION ALL ' +
    'CREATE MERGE SET DELETE DETACH REMOVE ON CASE WHEN THEN ELSE END EXISTS COUNT COLLECT DESC ASC CONTAINS STARTS ENDS ' +
    'SEARCH FOR SCORE INDEX VECTOR FULLTEXT POINT CONSTRAINT REQUIRE UNIQUE IF SHOW EXPLAIN PROFILE DROP EACH OPTIONS TRUE FALSE'
  ).split(' '),
);

export interface Token {
  text: string;
  kind: 'kw' | 'str' | 'num' | 'cmt' | 'plain';
}

export function highlightCypher(source: string): Token[] {
  const tokens: Token[] = [];
  const pattern = /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)|('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:``|[^`])*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)/g;
  let last = 0;
  let match: RegExpExecArray | null;
  const push = (text: string, kind: Token['kind']) => {
    if (!text) return;
    const previous = tokens[tokens.length - 1];
    if (previous && previous.kind === kind && kind === 'plain') previous.text += text;
    else tokens.push({ text, kind });
  };
  while ((match = pattern.exec(source))) {
    push(source.slice(last, match.index), 'plain');
    last = match.index + match[0].length;
    if (match[1]) push(match[0], 'cmt');
    else if (match[2]) push(match[0], match[0].startsWith('`') ? 'plain' : 'str');
    else if (match[3]) push(match[0], 'num');
    else {
      const before = source[match.index - 1];
      // `:WON`, `.year` and `$limit` are a type, a property and a parameter, not keywords.
      const isKeyword = KEYWORDS.has(match[0].toUpperCase()) && before !== ':' && before !== '.' && before !== '$';
      push(match[0], isKeyword ? 'kw' : 'plain');
    }
  }
  push(source.slice(last), 'plain');
  return tokens;
}
