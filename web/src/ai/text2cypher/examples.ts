// Question -> Cypher pairs shown to the model as few-shot examples. The ones
// nearest to the user's question (by embedding) go into the prompt.
//
// Every example is executed against the sample store in tests/text2cypher.test.ts,
// so a statement here is known to parse and run on Relate.

export interface Example {
  question: string;
  cypher: string;
}

export const EXAMPLES: Example[] = [
  { question: 'How many books are on my wishlist?', cypher: 'MATCH (b:Book)\nRETURN count(b) AS books' },
  {
    question: 'Which authors have the most books on my list?',
    cypher: 'MATCH (a:Author)<-[:WRITTEN_BY]-(b:Book)\nWITH a.name AS author, count(DISTINCT b) AS books\nRETURN author, books\nORDER BY books DESC, author\nLIMIT 10',
  },
  {
    question: 'What books by Ursula K. Le Guin do I have?',
    cypher: "MATCH (b:Book)-[:WRITTEN_BY]->(a:Author)\nWHERE toLower(a.name) CONTAINS 'le guin'\nRETURN DISTINCT b.title AS title, b.first_publish_year AS year\nORDER BY year\nLIMIT 25",
  },
  {
    question: 'Who wrote Project Hail Mary?',
    cypher: "MATCH (b:Book)-[:WRITTEN_BY]->(a:Author)\nWHERE toLower(b.title) CONTAINS 'project hail mary'\nRETURN DISTINCT b.title AS title, a.name AS author\nLIMIT 25",
  },
  {
    question: 'What are the highest rated books?',
    cypher: 'MATCH (b:Book)\nWHERE b.ol_rating > 0 AND b.ol_rating_count >= 5\nRETURN b.title AS title, round(b.ol_rating * 100) / 100.0 AS rating, b.ol_rating_count AS ratings\nORDER BY rating DESC\nLIMIT 10',
  },
  {
    question: 'What are the best rated books about history?',
    cypher: "MATCH (b:Book)-[:ABOUT]->(s:Subject)\nWHERE toLower(s.name) CONTAINS 'history' AND b.ol_rating > 0 AND b.ol_rating_count >= 5\nWITH DISTINCT b\nRETURN b.title AS title, round(b.ol_rating * 100) / 100.0 AS rating, b.ol_rating_count AS ratings\nORDER BY rating DESC\nLIMIT 10",
  },
  {
    question: 'Which books are about artificial intelligence?',
    cypher: "MATCH (b:Book)-[:ABOUT]->(s:Subject)\nWHERE toLower(s.name) CONTAINS 'artificial intelligence'\nRETURN DISTINCT b.title AS title, b.first_publish_year AS year\nORDER BY title\nLIMIT 25",
  },
  {
    question: 'Show me the science fiction books',
    cypher: "MATCH (b:Book)\nWHERE EXISTS { MATCH (b)-[:IN_GENRE]->(g:Genre) WHERE toLower(g.name) CONTAINS 'science fiction' }\n   OR EXISTS { MATCH (b)-[:ABOUT]->(s:Subject) WHERE toLower(s.name) CONTAINS 'science fiction' }\nRETURN b.title AS title, b.first_publish_year AS year, b.ol_rating AS rating\nORDER BY title\nLIMIT 25",
  },
  {
    question: 'Which books are set in San Francisco?',
    cypher: "MATCH (b:Book)-[:SET_IN]->(p:Place)\nWHERE toLower(p.name) CONTAINS 'san francisco'\nRETURN DISTINCT b.title AS title\nORDER BY title\nLIMIT 25",
  },
  {
    question: 'Where are most of my books set?',
    cypher: 'MATCH (b:Book)-[:SET_IN]->(p:Place)\nWITH coalesce(p.geocoded_label, p.name) AS place, count(DISTINCT b) AS books\nRETURN place, books\nORDER BY books DESC, place\nLIMIT 10',
  },
  {
    question: 'What are the oldest books on the list?',
    cypher: 'MATCH (b:Book)\nWHERE b.first_publish_year IS NOT NULL\nRETURN b.title AS title, b.first_publish_year AS year\nORDER BY year\nLIMIT 10',
  },
  {
    question: 'Which books were first published after 2015?',
    cypher: 'MATCH (b:Book)\nWHERE b.first_publish_year > 2015\nRETURN b.title AS title, b.first_publish_year AS year\nORDER BY year DESC\nLIMIT 25',
  },
  {
    question: 'How many books per decade?',
    cypher: 'MATCH (b:Book)\nWHERE b.first_publish_year IS NOT NULL\nRETURN (b.first_publish_year / 10) * 10 AS decade, count(*) AS books\nORDER BY decade',
  },
  {
    question: 'What are the longest books?',
    cypher: 'MATCH (b:Book)\nWHERE b.pages_median IS NOT NULL\nRETURN b.title AS title, b.pages_median AS pages\nORDER BY pages DESC\nLIMIT 10',
  },
  {
    question: 'Which books won the Hugo Award?',
    cypher: "MATCH (b:Book)-[w:WON]->(a:Award)\nWHERE toLower(a.name) CONTAINS 'hugo'\nRETURN b.title AS title, a.name AS award, w.year AS year\nORDER BY year\nLIMIT 25",
  },
  {
    question: 'Which authors have won a Nobel Prize?',
    cypher: "MATCH (a:Author)-[:WON]->(w:Award)\nWHERE toLower(w.name) CONTAINS 'nobel'\nRETURN a.name AS author, collect(DISTINCT w.name) AS awards\nORDER BY author\nLIMIT 25",
  },
  {
    question: 'Which authors won the most awards?',
    cypher: 'MATCH (a:Author)-[:WON]->(w:Award)\nWITH a.name AS author, count(DISTINCT w) AS awards\nRETURN author, awards\nORDER BY awards DESC, author\nLIMIT 10',
  },
  {
    question: 'Books by British authors',
    cypher: "MATCH (b:Book)-[:WRITTEN_BY]->(a:Author)-[:CITIZEN_OF]->(c:Country)\nWHERE c.name = 'United Kingdom'\nRETURN DISTINCT b.title AS title, a.name AS author\nORDER BY title\nLIMIT 25",
  },
  {
    question: 'Which authors are American?',
    cypher: "MATCH (a:Author)-[:CITIZEN_OF]->(c:Country)\nWHERE c.name = 'United States'\nRETURN DISTINCT a.name AS author\nORDER BY author\nLIMIT 25",
  },
  {
    question: 'Which authors were born in Oakland?',
    cypher: "MATCH (a:Author)-[:BORN_IN]->(p:Place)\nWHERE toLower(p.name) CONTAINS 'oakland'\nRETURN a.name AS author, p.name AS birthplace\nORDER BY author\nLIMIT 25",
  },
  {
    question: 'Which countries are my authors from?',
    cypher: 'MATCH (a:Author)-[:CITIZEN_OF]->(c:Country)\nRETURN c.name AS country, count(DISTINCT a) AS authors\nORDER BY authors DESC, country\nLIMIT 25',
  },
  {
    question: 'Which books are part of a series?',
    cypher: 'MATCH (b:Book)-[r:PART_OF]->(s:Series)\nRETURN s.name AS series, r.position AS position, b.title AS title\nORDER BY series, position\nLIMIT 25',
  },
  {
    question: 'What are the cheapest Kindle editions?',
    cypher: "MATCH (e:Edition)-[:EDITION_OF]->(b:Book)\nWHERE e.format = 'Kindle Edition' AND e.price IS NOT NULL\nRETURN b.title AS title, e.price AS price, e.currency AS currency\nORDER BY price\nLIMIT 10",
  },
  {
    question: 'How much would the whole wishlist cost?',
    cypher: 'MATCH (:Wishlist)-[:CONTAINS]->(i:Item)\nWHERE i.price IS NOT NULL\nRETURN round(sum(i.price) * 100) / 100.0 AS total, count(i) AS priced_items',
  },
  {
    question: 'What is the average price by format?',
    cypher: 'MATCH (e:Edition)\nWHERE e.price IS NOT NULL AND e.format IS NOT NULL\nRETURN e.format AS format, count(*) AS editions, round(avg(e.price) * 100) / 100.0 AS average_price\nORDER BY editions DESC\nLIMIT 10',
  },
  {
    question: 'Which publishers have the most books on my list?',
    cypher: 'MATCH (e:Edition)-[:PUBLISHED_BY]->(p:Publisher)\nRETURN p.name AS publisher, count(DISTINCT e) AS editions\nORDER BY editions DESC, publisher\nLIMIT 10',
  },
  {
    question: 'Which books share the most subjects with Red Mars?',
    cypher: "MATCH (b:Book)-[:ABOUT]->(s:Subject)<-[:ABOUT]-(other:Book)\nWHERE toLower(b.title) CONTAINS 'red mars' AND other <> b\nRETURN other.title AS title, count(DISTINCT s) AS shared_subjects\nORDER BY shared_subjects DESC, title\nLIMIT 10",
  },
  {
    question: 'What subjects does The Left Hand of Darkness cover?',
    cypher: "MATCH (b:Book)-[:ABOUT]->(s:Subject)\nWHERE toLower(b.title) CONTAINS 'left hand of darkness'\nRETURN s.name AS subject\nORDER BY subject\nLIMIT 50",
  },
  {
    question: 'What are the most common subjects?',
    cypher: 'MATCH (b:Book)-[:ABOUT]->(s:Subject)\nWITH toLower(s.name) AS subject, count(DISTINCT b) AS books\nRETURN subject, books\nORDER BY books DESC, subject\nLIMIT 15',
  },
  {
    question: 'Which books feature Sherlock Holmes?',
    cypher: "MATCH (b:Book)-[:FEATURES]->(p:Person)\nWHERE toLower(p.name) CONTAINS 'sherlock holmes'\nRETURN DISTINCT b.title AS title, p.name AS person\nORDER BY title\nLIMIT 25",
  },
  {
    question: 'Which books are set during World War II?',
    cypher: "MATCH (b:Book)-[:SET_DURING]->(e:Era)\nWHERE toLower(e.name) CONTAINS 'world war'\nRETURN DISTINCT b.title AS title, e.name AS era\nORDER BY title\nLIMIT 25",
  },
  {
    question: 'Which books do the most Open Library readers want to read?',
    cypher: 'MATCH (b:Book)\nWHERE b.ol_want_to_read IS NOT NULL\nRETURN b.title AS title, b.ol_want_to_read AS want_to_read\nORDER BY want_to_read DESC\nLIMIT 10',
  },
  {
    question: 'Which authors do I have more than one book by?',
    cypher: 'MATCH (a:Author)<-[:WRITTEN_BY]-(b:Book)\nWITH a.name AS author, count(DISTINCT b) AS books, collect(DISTINCT b.title) AS titles\nWHERE books > 1\nRETURN author, books, titles\nORDER BY books DESC, author\nLIMIT 25',
  },
  {
    question: 'How many books have no rating?',
    cypher: 'MATCH (b:Book)\nWHERE b.ol_rating IS NULL OR b.ol_rating = 0\nRETURN count(b) AS unrated_books',
  },
  {
    question: 'Find books whose description mentions whales',
    cypher: "MATCH (b:Book)\nSEARCH b IN (FULLTEXT INDEX book_text FOR 'whales' LIMIT 10) SCORE AS score\nRETURN b.title AS title, score\nORDER BY score DESC",
  },
  {
    question: 'What genres are on my list?',
    cypher: 'MATCH (b:Book)-[:IN_GENRE]->(g:Genre)\nRETURN g.name AS genre, count(DISTINCT b) AS books\nORDER BY books DESC, genre\nLIMIT 25',
  },
  {
    question: 'Show the graph of books by Andy Weir',
    cypher: "MATCH p = (b:Book)-[:WRITTEN_BY]->(a:Author)\nWHERE toLower(a.name) CONTAINS 'andy weir'\nRETURN p\nLIMIT 50",
  },
  {
    question: 'Draw the books set in Montana and their authors',
    cypher: "MATCH p = (pl:Place)<-[:SET_IN]-(b:Book)-[:WRITTEN_BY]->(a:Author)\nWHERE toLower(pl.name) CONTAINS 'montana'\nRETURN p\nLIMIT 50",
  },
  {
    question: 'Show a graph of Red Mars and everything connected to it',
    cypher: "MATCH p = (b:Book)-[r]-(x)\nWHERE toLower(b.title) CONTAINS 'red mars'\nRETURN p\nLIMIT 60",
  },
  {
    question: 'Show The Left Hand of Darkness and its awards as a graph',
    cypher: "MATCH p = (b:Book)-[:WON]->(a:Award)\nWHERE toLower(b.title) CONTAINS 'left hand of darkness'\nRETURN p\nLIMIT 50",
  },
  {
    question: 'Who published A Truck Full of Money?',
    cypher: "MATCH (p:Publisher)<-[:PUBLISHED_BY]-(e:Edition)-[:EDITION_OF]->(b:Book)\nWHERE toLower(b.title) CONTAINS 'truck full of money'\nRETURN DISTINCT p.name AS publisher, e.format AS format\nLIMIT 25",
  },
  {
    question: 'Where is Project Hail Mary set?',
    cypher: "MATCH (b:Book)-[:SET_IN]->(p:Place)\nWHERE toLower(b.title) CONTAINS 'project hail mary'\nRETURN DISTINCT p.name AS place\nORDER BY place\nLIMIT 50",
  },
  {
    question: 'Which books were first published before 1980?',
    cypher: 'MATCH (b:Book)\nWHERE b.first_publish_year < 1980\nRETURN b.title AS title, b.first_publish_year AS year\nORDER BY year\nLIMIT 25',
  },
  {
    question: 'Which hardcover books are under 15 dollars?',
    cypher: "MATCH (e:Edition)-[:EDITION_OF]->(b:Book)\nWHERE e.format = 'Hardcover' AND e.price < 15\nRETURN b.title AS title, e.price AS price\nORDER BY price\nLIMIT 25",
  },
  {
    question: 'What is the average rating of my books?',
    cypher: 'MATCH (b:Book)\nWHERE b.ol_rating > 0\nRETURN round(avg(b.ol_rating) * 100) / 100.0 AS average_rating, count(b) AS rated_books',
  },
];
