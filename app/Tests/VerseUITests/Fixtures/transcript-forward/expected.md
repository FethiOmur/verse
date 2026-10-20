# Courier planner review

15 Oct 2026 · Meeting · 7 turns

**0:05 Dana:** Good morning everyone, thanks for joining.

**0:22 Other:** Good morning. Can you walk us through the route planner you built?

> Card (F · D): The planner builds delivery routes for a small courier fleet and re-plans when an order changes.
> - Fleet of eight vans, one depot
> - Re-plans in under two seconds
> - Written in Python with OR-Tools

**0:38 Dana:** Yes. It plans delivery routes for a small courier fleet.

**0:40 Other:** How did you measure whether the new routes were actually better?

> Card (F): We compared kilometres per delivery before and after the change, over six weeks, and the median route got about eleven percent shorter.
> - Baseline: the dispatcher's manual routes
> - Six weeks, 1,200 deliveries

**1:10 Dana:** We compared kilometres per delivery before and after, over six weeks.

**1:01:20 Other:** Welcome back. We lost you for a moment; shall we continue with costs?

> Card (F): Costs are small: the infrastructure is about forty dollars a month.
> - One small server, no per-seat licences

**1:02:05 Dana:** Yes please. The infrastructure costs about forty dollars a month.

> Card (F): If asked about scaling: the same design handles a few hundred vans.
