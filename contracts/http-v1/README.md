# PrasenzPrinter HTTP v1

`POST /print` receives an arbitrary PDF binary body and immediately returns `200 {"success":true,"message":"Successfully enqueued print job"}` after it has been placed in the in-memory queue. It does not promise that a PDF is valid or that paper has printed.

Required header: `x-printer-name`. Missing or blank returns `400 {"error":"Missing x-printer-name header"}`. An empty body returns `400 {"error":"Input PDF data is empty"}`. Headers are case-insensitive. Unknown paths and methods return `404 {"error":"Not Found"}`.

`x-print-options` is optional. Its absence means fit-to-page. A present-but-empty header is intentionally distinct and sends no explicit Sumatra setting. Supported values are `-o fit-to-page`, `-o scaling=100`, `-o media=A4`, `-o media=Letter`, `-o media=custom_*`, `-n N`, `-o copies=N`, `-o sides=one-sided`, `-o sides=two-sided-long-edge`, `-o sides=two-sided-short-edge`, and zero-valued `page-left/right/top/bottom` options. Unsupported values return `400` before enqueue.

`page-*` margins and custom media are accepted to preserve request compatibility but require manual validation with the pinned SumatraPDF release and target printer driver before release. Their current command-line mapping is not an output guarantee.

The Windows implementation limits a request body to 50 MiB; requests over that limit return `413 {"error":"Input PDF exceeds the 50 MiB limit"}`. Queue capacity is not bounded in v1; jobs are in memory and are lost on process restart.

`p-req-id` is optional and is copied to print logs. Cloudflare Access headers are passed through without local validation.

`GET /health` returns `status`, `version`, `arch` (`x86_64`), integer `uptime`, pending-only `queueLength`, `tunnelActive`, `tunnelStatus`, and `tunnelErrorMessage`.
