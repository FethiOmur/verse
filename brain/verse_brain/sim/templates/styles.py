"""Inline stylesheet of report.html. Dark, one muted accent, system type, no gradients, shadows or scripts."""

CSS = """
:root{--bg:#050405;--ink:#eae5ec;--mute:#9a929f;--faint:#6d6672;--rule:#2a262d;--panel:#0d0b0e;--accent:#8fb8ab}
*{box-sizing:border-box}
html{background:var(--bg);color-scheme:dark}
body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
main{overflow-wrap:anywhere;max-width:760px;margin:0 auto;padding:56px 24px 96px}
h1,h2,h3,p,ul,ol,dl,dd,figure,blockquote{margin:0}
h1{font-size:34px;line-height:1.15;font-weight:600;letter-spacing:-.01em}
h2{font-size:13px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--mute)}
h3{font-size:19px;line-height:1.35;font-weight:600}
.meta{margin-top:10px;color:var(--mute);font-size:15px}
section{margin-top:56px}
section>h2{padding-bottom:12px;border-bottom:1px solid var(--rule);margin-bottom:24px}
.notice{margin-top:28px;padding:14px 16px;border:1px solid var(--rule);border-left:3px solid var(--accent);background:var(--panel);font-size:15px;color:var(--ink)}
.notice+.notice{margin-top:10px}
.hero{display:flex;align-items:baseline;gap:20px;margin-top:40px}
.big{font-size:84px;line-height:1;font-weight:300;letter-spacing:-.03em;font-variant-numeric:tabular-nums}
.big small{font-size:28px;color:var(--faint);font-weight:300}
.hero p{color:var(--mute);font-size:15px;max-width:34ch}
.comp{padding:18px 0;border-bottom:1px solid var(--rule)}
.comp:first-of-type{padding-top:0}
.comp-head{display:flex;justify-content:space-between;gap:16px;align-items:baseline}
.comp-head strong{font-weight:600}
.score{font-variant-numeric:tabular-nums;color:var(--accent);font-weight:600;white-space:nowrap}
.bar{display:flex;gap:4px;margin:10px 0 10px}
.bar i{display:block;height:4px;flex:1;background:var(--rule)}
.bar i.on{background:var(--accent)}
.comp p{font-size:15px;color:var(--mute)}
.comp .quote{margin-top:4px;color:var(--faint);font-size:14px}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:0;border-top:1px solid var(--rule)}
.stat{padding:18px 16px 18px 0;border-bottom:1px solid var(--rule)}
.stat dt{font-size:13px;color:var(--mute)}
.stat dd{margin-top:6px;font-size:30px;font-weight:300;font-variant-numeric:tabular-nums;letter-spacing:-.01em}
.stat dd small{font-size:14px;color:var(--faint);margin-left:4px;letter-spacing:0}
.note{margin-top:14px;font-size:14px;color:var(--faint)}
.practise{padding-left:0;list-style:none;counter-reset:p}
.practise li{counter-increment:p;padding:14px 0 14px 40px;border-bottom:1px solid var(--rule);position:relative}
.practise li::before{content:counter(p);position:absolute;left:0;top:14px;color:var(--accent);font-weight:600;font-variant-numeric:tabular-nums}
.q{padding:32px 0;border-top:1px solid var(--rule)}
.q:first-of-type{border-top:0;padding-top:0}
.q-tag{font-size:13px;color:var(--mute);margin-bottom:6px}
.q-tag b{color:var(--accent);font-weight:600}
.said{margin-top:18px}
.label{font-size:12px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--faint);margin-bottom:6px}
.answer{border-left:2px solid var(--rule);padding-left:16px;color:#cfc9d3;font-size:16px}
.answer+.answer{margin-top:10px}
.follow{margin-top:14px;color:var(--mute);font-size:15px}
.deliv{margin-top:14px;font-size:14px;color:var(--mute);font-variant-numeric:tabular-nums}
.deliv span+span::before{content:"\\00b7";margin:0 8px;color:var(--faint)}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:24px}
.cols ul{padding-left:18px;font-size:15px}
.cols li+li{margin-top:6px}
.better{margin-top:24px;padding:16px 18px;background:var(--panel);border-left:2px solid var(--accent)}
.better p{font-size:16px}
.better p+p{margin-top:6px}
.src{margin-top:12px;font-size:13px;color:var(--faint)}
.src div+div{margin-top:3px}
.src b{color:var(--mute);font-weight:600}
.skipped{margin-top:14px;color:var(--mute);font-style:normal}
.coach{margin-top:14px;font-size:14px;color:var(--faint)}
footer{margin-top:64px;padding-top:16px;border-top:1px solid var(--rule);font-size:13px;color:var(--faint)}
@media (max-width:640px){main{padding:36px 16px 72px}h1{font-size:28px}.big{font-size:64px}.stats{grid-template-columns:repeat(2,1fr)}.cols{grid-template-columns:1fr}.hero{flex-direction:column;gap:8px}}
@media print{html,body{background:#fff;color:#000}}
"""
