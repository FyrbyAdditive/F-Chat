---
license: apache-2.0
base_model:
- Qwen/Qwen3-0.6B-Base
library_name: transformers
pipeline_tag: text-ranking
tags:
- mlx
---

# mlx-community/Qwen3-Reranker-0.6B-mxfp8

The Model [mlx-community/Qwen3-Reranker-0.6B-mxfp8](https://huggingface.co/mlx-community/Qwen3-Reranker-0.6B-mxfp8) was converted to MLX format from [Qwen/Qwen3-Reranker-0.6B](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B) using [mlx-embeddings](https://github.com/Blaizzy/mlx-embeddings) version **0.0.3**.

## Use with mlx

```bash
pip install mlx-embeddings
```

```python
from mlx_embeddings import load, generate
import mlx.core as mx

model, tokenizer = load("mlx-community/Qwen3-Reranker-0.6B-mxfp8")

# For text embeddings
output = generate(model, processor, texts=["I like grapes", "I like fruits"])
embeddings = output.text_embeds  # Normalized embeddings

# Compute dot product between normalized embeddings
similarity_matrix = mx.matmul(embeddings, embeddings.T)

print("Similarity matrix between texts:")
print(similarity_matrix)


```
