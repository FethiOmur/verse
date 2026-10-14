# Interview prep: Senior AI Engineer at Halden Freight Systems

Call: Thursday 22 October 2026, 15:00 CEST, Google Meet, 45 minutes.
Panel: Ingrid Solberg (VP Engineering, hiring manager) and Tomas Weir (tech lead, platform team).

## About the company
- Halden Freight Systems builds route-planning software for mid-size European haulage firms.
- About 140 employees; the AI team has 6 people and reports to Ingrid.
- Their product Compass re-plans delivery routes every 90 seconds using live traffic and driver status.
- They are moving from rules-based dispatch to an LLM-assisted dispatcher, pilot planned for Q1 2027.

## My story in three lines
- I led the Lantern project: an LLM pipeline that extracts structured fields from supplier invoices.
- Lantern cut manual data entry from 11 minutes to 2 minutes per invoice and ran on 38,000 invoices a month.
- I also built a small route optimiser for a courier pilot that reduced empty runs by 14 percent.

## Numbers I should have ready
- Lantern accuracy on the held-out set was 96.4 percent for totals and 91 percent for line items.
- Low-confidence fields (below 0.8) go to a human operator; that was about 7 percent of invoices.
- Monthly model cost for Lantern was around EUR 1,900 against EUR 9,500 of manual labour saved.
- The courier pilot ran for 10 weeks across 23 vans in Milan.

## Technical decisions I can defend
- Schema-validated extraction with one retry, then escalate; never let the model guess a total.
- I chose a small model for the first pass and a larger one only on low-confidence documents.
- Evaluation: a frozen set of 400 invoices, rerun on every prompt change before release.
- Weakness: I used to over-engineer early prototypes; now I ship a thin version in the first week.

## Questions to ask them
- How will the dispatcher be evaluated before it touches live routes?
- What does the on-call rotation for the AI team look like?
- Which part of Compass is hardest to test today?

## Logistics and risks
- Notice period at my current company is 30 days, so earliest start is mid-December 2026.
- Salary expectation: EUR 70,000 to 80,000 gross per year; flexible for equity.
- Glossary: ETA drift means the gap between the promised and the actual arrival time.
