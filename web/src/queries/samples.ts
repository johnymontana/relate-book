// Starting points for the Query tab: questions to ask in English, and Cypher to run as written.

export const SAMPLE_QUESTIONS = [
  'Which authors have the most books on my list?',
  'What are the highest rated books?',
  'Which books are set in San Francisco?',
  'Show me the science fiction books',
  'Which books won awards, and which awards?',
  'How much would the whole wishlist cost?',
  'What are the cheapest Kindle editions?',
  'Which books share the most subjects with Red Mars?',
  'Show the graph of books by Andy Weir',
];

export const SAMPLE_CYPHER: Array<{ title: string; cypher: string }> = [
  {
    title: 'List, by priority and rating',
    cypher: 'MATCH (w:Wishlist)-[c:CONTAINS]->(i:Edition)-[:EDITION_OF]->(b:Book)\nRETURN i.title AS title, i.format AS format, c.priority_label AS priority, i.price AS price, b.ol_rating AS rating\nORDER BY c.priority DESC, rating DESC\nLIMIT 25',
  },
  {
    title: 'A book and everything around it',
    cypher: 'MATCH p = (b:Book)-[r]-(x)\nWHERE b.first_publish_year < 1975\nRETURN p\nLIMIT 60',
  },
  {
    title: 'Fulltext search (SEARCH clause)',
    cypher: "MATCH (b:Book)\nSEARCH b IN (FULLTEXT INDEX book_text FOR 'mars OR mystery' LIMIT 10) SCORE AS score\nRETURN b.title AS title, score\nORDER BY score DESC",
  },
  {
    title: 'Places near San Francisco (point index)',
    cypher: 'MATCH (p:Place)\nWHERE p.location IS NOT NULL\nWITH p, point.distance(p.location, point({latitude: 37.7749, longitude: -122.4194})) AS metres\nRETURN p.name AS place, round(metres / 1000.0) AS km\nORDER BY km\nLIMIT 10',
  },
  {
    title: 'Books that share subjects',
    cypher: 'MATCH (b1:Book)-[:ABOUT]->(s:Subject)<-[:ABOUT]-(b2:Book)\nWHERE b1.key < b2.key\nWITH b1, b2, count(s) AS shared\nWHERE shared >= 2\nRETURN b1.title AS book, b2.title AS other, shared\nORDER BY shared DESC\nLIMIT 20',
  },
  {
    title: 'Authors, awards and countries',
    cypher: 'MATCH p = (c:Country)<-[:CITIZEN_OF]-(a:Author)-[:WON]->(w:Award)\nRETURN p\nLIMIT 40',
  },
  { title: 'Indexes in this store', cypher: 'SHOW INDEXES YIELD name, type, labelsOrTypes, properties\nRETURN name, type, labelsOrTypes, properties\nORDER BY type, name' },
  { title: 'A query plan', cypher: 'EXPLAIN MATCH (a:Author)<-[:WRITTEN_BY]-(b:Book)\nWHERE b.first_publish_year > 1990\nRETURN a.name, count(b) AS books\nORDER BY books DESC\nLIMIT 5' },
  {
    title: 'Vector search from a book (needs embeddings)',
    cypher: "MATCH (s:Book)\nWHERE s.embedding IS NOT NULL\nWITH s ORDER BY s.title LIMIT 1\nMATCH (b:Book)\nSEARCH b IN (VECTOR INDEX book_embedding FOR s.embedding LIMIT 6) SCORE AS score\nRETURN s.title AS near, b.title AS title, round(score * 1000) / 1000.0 AS score\nORDER BY score DESC",
  },
];
