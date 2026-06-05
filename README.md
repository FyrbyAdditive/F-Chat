<p align="center">
  <img src="Sources/FyxLocalApp/Resources/AppLogo.png" alt="FyxLocal" width="160" height="160">
</p>

<h1 align="center">FyxLocal</h1>

After looking through various open source clients and being dissatisfied with all of them in various different ways I set out to make my own with the following objectives.

* I'm not a big fan of big-AI, and want to keep it local and not creepy with a focus on privacy where possible.
* The interface should be clean, easy to understand and therefore expose features in a hopefully obvious way.
* Not bundle lots of commercial providers built in, but include support for the most popular APIs used by locally running models, if there is commercial cross-over (there is) that's fine.
* Users should opt-in to skills, MCP services and so on and we should not bundle any, to keep the client clean and minimal.

If you plan to contribute to FyxLocal please bear in mind the above, and that I would like to keep the client as clean, un-commercialised and local as possible. That means a provider probably won't specifically be added unless it has a commonly used or open API.

This client has the following features:

* Skills, including sandboxed Python/bash script support
* MCP via stdio/http with API key or OAuth
* RAG funtionality including:
  * Local embedding via on-device Qwen3-Embedding-0.6B 8-bit
  * Hybrid keyword & vector search
  * Reranking via on-device Qwen3-Reranker-0.6B 8-bit
* Cross-chat search
* Import from Anthropic/OpenAI exports
* Export to multiple file formats

The latest version has support for various tools, including:

* Web search and web fetch
* Time of day
* Chart creation
* Local integration of Apple Maps, Reminders, Calendar and Contacts

_Please note that some of these tools have optional write access (disabled by default) and that you use these at your own risk. Different LLMs will perform vastly differently with these tools, and I am not responsible for anything they do or your choice to use these features._

The following provider types are supported, which are included as they work with certain models via vLLM:

* OpenAI Responses API
* OpenAI Completions API
* Anthropic Messages API (via Platform API, not a claude.ai account)

Currently FyxLocal has English, Swedish and Danish localisations and is open to submissions for more.

-------
<p></p>
<p align="center">
  <img src="Sources/FyxLocalApp/Resources/FameLogo.png" alt="Fyrby Additive Manufacturing &amp; Engineering" width="280">
</p>

<p align="center">
  Copyright 2026 Tim Ellis, Fyrby Additive Manufacturing &amp; Engineering
</p>