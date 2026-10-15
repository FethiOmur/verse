## INTERVIEW
Company: Brightwave
Role: AI Engineer
Type: mixed | Difficulty: standard | Length: 30 min | Language: en

## COMPETENCIES (what the posting asks for)
[c1] Grounding and hallucination fixes | posting: "The agent sometimes says a product is unavailable when it's in stock."
[c2] Hybrid exact and semantic retrieval | posting: "We need both, in one ranking."
[c3] Multilingual quality | posting: "An agent that answers in the wrong language is worse than one that says nothing."
[c4] Latency and cost | posting: "You'll profile requests, test prompt and model changes, and ship improvements you can point at on a graph."
[c5] Evals that predict production | posting: "Making it actually predict production quality is open work."
[c6] Reading traces and debugging | posting: "Given a bad answer in production, you can find why: retrieval missed, the prompt was wrong, the model picked the wrong tool."
[c7] Scoring and suppressing proactive insights | posting: "Ranking, scoring, and suppressing proactive insights so the agent interrupts a customer only when it has earned it."
[c8] RAG fundamentals | posting: "You know how RAG actually behaves: embeddings, vector search, chunking, reranking, and where each one breaks."

## CANDIDATE EVIDENCE (the only facts about the candidate; each is sourced)
[e1] skill | 4 years of professional experience as a software engineer, the last two on LLM features used by real customers.
    source: cv:L5 "4 years of professional experience, the last two on LLM features used by real customers"
[e2] project | Built a product-question assistant for a fashion webshop, with pgvector retrieval over 38,000 catalogue items and answers in Swedish and English.
    source: cv:L9 "retrieval over 38,000 catalogue items with pgvector, answers in Swedish and English"
[e3] metric | Cut out-of-stock hallucinations from 9% to 2% with an exact SKU and size lookup before semantic search plus a grounding check on the final answer.
    source: cv:L10 "hallucinations from 9% to 2% by adding an exact SKU and size lookup before semantic search and a grounding check on the final answer"
[e4] metric | Reduced median answer latency from 4.1 s to 2.3 s by caching embeddings, trimming the prompt and streaming the first sentence.
    source: cv:L11 "Reduced median answer latency from 4.1 s to 2.3 s by caching embeddings, trimming the prompt and streaming the first sentence"
[e5] project | Set up Langfuse tracing for every conversation and a golden set of 220 questions that runs in CI before each prompt change.
    source: cv:L12 "Set up Langfuse tracing for every conversation and a golden set of 220 questions that runs in CI before each prompt change"
[e6] metric | Added a cross-encoder reranking step; recall at 5 went from 0.71 to 0.84 on the golden set.
    source: cv:L13 "Wrote a reranking step with a cross-encoder; recall at 5 went from 0.71 to 0.84 on the golden set"
[e7] project | Wrote an open-source eval harness for retrieval systems with 140 GitHub stars, used by two other teams at Nordlys Commerce.
    source: cv:L21 "Open-source eval harness for retrieval systems: 140 GitHub stars, used by two other teams at Nordlys Commerce"
[e8] story | Built an Italian-language recipe chatbot as a side project to learn how multilingual prompts fail.
    source: cv:L22 "Side project: Italian-language recipe chatbot, built to learn how multilingual prompts fail."
[e9] project | Owned the shipment-tracking API in Python and FastAPI, serving 1.2 million requests per day.
    source: cv:L16 "Owned the shipment-tracking API in Python and FastAPI, serving 1.2 million requests per day."
[e10] metric | Moved a nightly batch job to a queue-based pipeline, cutting data delay from 6 hours to 15 minutes.
    source: cv:L17 "Moved a nightly batch job to a queue-based pipeline, which brought the data delay from 6 hours to 15 minutes."

## QUESTION PLAN
[q1] opener | Thanks for joining. To start, could you tell me a bit about yourself and what you have been building recently?
    competencies: c8 | evidence: e1, e2 | target: 60-90 s
[q2] motivation | What draws you to Brightwave and to this AI Engineer role in particular?
    competencies: c7 | evidence: - | target: 60-90 s
    follow-up: What part of building proactive agents interests you most?
    follow-up: What would you want to have owned after your first few months?
[q3] technical | Imagine our agent tells a customer that a product is unavailable when it is actually in stock. How would you find out why, and how would you fix it?
    competencies: c1, c6 | evidence: e3, e5 | target: 90-150 s
    follow-up: What would you look at first in the trace?
    follow-up: How would you prove the fix worked and stays fixed?
[q4] technical | Semantic search handles a warm jacket for winter well but struggles with a SKU or a specific size. How would you combine exact and semantic matching in one ranking?
    competencies: c2, c8 | evidence: e3, e6, e2 | target: 90-150 s
    follow-up: How would you decide how to weigh the two signals?
    follow-up: Where does a reranker fit, and where does it break down?
[q5] behavioural | Tell me about a time you worked on an assistant that had to answer in more than one language. What went wrong, and what did you do about it?
    competencies: c3 | evidence: e2, e8 | target: 60-120 s
    follow-up: How did you measure quality in each language?
    follow-up: What would you do differently now?
[q6] behavioural | Tell me about a time you made an LLM feature faster or cheaper. How did you find the bottleneck?
    competencies: c4 | evidence: e4 | target: 60-120 s
    follow-up: What was the number before and after?
    follow-up: Did any change hurt answer quality, and how did you check?
[q7] technical | Our golden-dataset harness does not yet predict production quality well. How would you go about making it more predictive?
    competencies: c5, c6 | evidence: e5, e7 | target: 90-150 s
    follow-up: Where would new test cases come from?
    follow-up: How would you know the eval score and production quality actually agree?
[q8] role | Suppose a proactive agent has ten possible things it could tell a customer right now. How would you decide which one, if any, is worth saying?
    competencies: c7 | evidence: - | target: 90-150 s
    follow-up: What signals would you use to score an insight?
    follow-up: How would you measure whether suppressing an insight was the right call?

## RUBRIC
[c1] Grounding and hallucination fixes
    1: Blames the model in general and proposes a vague prompt tweak, with no way to locate or verify the cause.
    3: Separates retrieval, prompt and model causes and suggests a stock or grounding check, but gives little measurement.
    5: Traces the failing case, adds exact lookup and a grounding check against stock data, and shows the hallucination rate falling with numbers on a fixed test set.
[c2] Hybrid exact and semantic retrieval
    1: Treats semantic search as the only option and cannot explain why SKUs and sizes fail.
    3: Describes combining keyword or exact lookup with vector search, but is vague about how the results are merged.
    5: Explains how exact and semantic results are merged in one ranking, with weighting and reranking, and checks the result against recall on a golden set.
[c3] Multilingual quality
    1: Says the model handles any language and has no way to detect wrong-language answers.
    3: Knows multilingual prompts fail and describes language detection or per-language checks.
    5: Gives a concrete failure, enforces answer language, tests each language on its own set, and reports the improvement.
[c4] Latency and cost
    1: Talks about speed in general terms with no measurement or numbers.
    3: Profiles requests and names sensible changes such as caching or shorter prompts, with partial numbers.
    5: Measures before and after on latency and cost, names the bottleneck, ships specific changes, and checks that quality did not drop.
[c5] Evals that predict production
    1: Relies on manual spot checks or a static test set with no link to production.
    3: Maintains a golden set and runs it before changes, but does not check whether scores match real outcomes.
    5: Grows the golden set from real production traces, validates eval scores against production quality, and runs the evals in CI to block regressions.
[c6] Reading traces and debugging
    1: Cannot say where to look for the cause of a bad answer.
    3: Reads a trace and sorts the failure into retrieval, prompt or tool choice.
    5: Walks through a trace step by step, isolates retrieval, prompt or tool selection as the cause, and turns the finding into a fix and a regression test.
[c7] Scoring and suppressing proactive insights
    1: Suggests sending every possible insight or picks at random, with no notion of cost to the customer.
    3: Proposes scoring insights by relevance and setting a threshold, with limited thought on measurement.
    5: Designs a scoring and suppression approach with clear signals and an explicit cost of interrupting, and plans to measure suppressed versus sent insights.
[c8] RAG fundamentals
    1: Only names RAG components and cannot say how or where they fail.
    3: Explains embeddings, chunking and reranking with some failure modes seen in practice.
    5: Explains where each RAG stage breaks with real examples from production, backed by measured results such as recall.
