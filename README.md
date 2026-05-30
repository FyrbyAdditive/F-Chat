<p align="center">
  <img src="Sources/FChatApp/Resources/AppLogo.png" alt="F-Chat" width="160" height="160">
</p>

<h1 align="center">F-Chat</h1>

After looking through various open source clients and being dissatisfied with all of them in various different ways, I set out to make my own with the following objectives.

* The interface should be clean, easy to understand and therefore expose features in a hopefully obvious way.
* Focus on doing as much as possible locally for privacy reasons
* Not bundle lots of commercial providers built in, but include support for the most popular APIs used by locally running models, if there is commercial cross-over (there is) that's fine.
* Users should opt-in to skills, MCP services and so on and we should not bundle any, to keep the client clean and minimal.

If you plan to contribute to F-Chat please bear in mind the above, and that I would like to keep the client as clean, un-commercialised and local as possible.

This client has the following features:

* Skills, including sandboxed Python/bash script support
* MCP via stdio/http with API key or OAuth
* RAG, with local embedding via Qwen3-Embedding-4B
* Extensible in-built tools with a basic set provided
* Import from Anthropic/OpenAI exports
* Export to multiple file formats

The following provider types are supported, which are included as they work with certain models via vLLM:

* OpenAI Responses API
* Anthropic Messages API (via their Platform API, not a claude.ai account)

Currently F-Chat has English, Swedish and Danish localisations and is open to submissions for more.

-------
<p></p>
<p align="center">
  <img src="Sources/FChatApp/Resources/FameLogo.png" alt="Fyrby Additive Manufacturing &amp; Engineering" width="280">
</p>

<p align="center">
  Copyright 2026 Tim Ellis, Fyrby Additive Manufacturing &amp; Engineering
</p>