#!/usr/bin/env python3
"""Vector store persistence check for restarttest.

  create <file>  create a milvus vector store, insert chunks, save its id
  verify <file>  query the saved store; fail if it 404s or returns no chunks

Catches the milvus bug where register_vector_store did not persist the
registration to kvstore, so stores 404 on query after a server restart.
"""
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from demos.common.utils import load_demo_config
from demos.rag.demo import OGXDemo

DOCS = [
    {"content": "RAG combines vector search with an LLM to ground answers in your data.",
     "metadata": {"source": "restarttest", "topic": "rag"}},
    {"content": "Milvus is a vector database used for similarity search over embeddings.",
     "metadata": {"source": "restarttest", "topic": "milvus"}},
]
QUERY = "What is Milvus used for?"


def make_demo() -> OGXDemo:
    # argv=[] so our subcommand/file args aren't parsed as demo config
    c = load_demo_config(argv=[])
    if not c["ogx_url"]:
        print("ERROR: OGX_URL is required")
        sys.exit(1)
    demo = OGXDemo(c["ogx_url"], c["keycloak_url"], c["username"], c["password"],
                   c["client_secret"], inference_model=c["inference_model"],
                   embedding_model=c["embedding_model"],
                   embedding_dimension=c["embedding_dimension"])
    if not demo.check_health():
        sys.exit(1)
    return demo


def create(id_file: str) -> None:
    demo = make_demo()
    vs_id = demo.create_vector_store("restarttest-kb")
    if not vs_id:
        sys.exit(1)
    embeddings = demo.generate_embeddings([d["content"] for d in DOCS])
    if not embeddings or not demo.insert_vectors(vs_id, DOCS, embeddings):
        sys.exit(1)
    Path(id_file).write_text(vs_id)
    print(f"Saved vector store id: {vs_id}")


def verify(id_file: str) -> None:
    demo = make_demo()
    vs_id = Path(id_file).read_text().strip()
    print(f"Querying vector store: {vs_id}")
    chunks = demo.query_vectors(vs_id, QUERY, top_k=3)
    if not chunks:
        print(f"FAIL: vector store '{vs_id}' returned no chunks after restart "
              "(404 => registration not persisted to kvstore).")
    else:
        print(f"OK: vector-io query returned {len(chunks)} chunk(s)")

    # Also verify via the OpenAI-compatible search endpoint
    results = demo.search_vector_store(vs_id, QUERY, top_k=3)
    if not results:
        print(f"FAIL: vector store '{vs_id}' returned no results from "
              "/v1/vector_stores/{id}/search after restart.")
        sys.exit(1)
    print(f"OK: vector store survived restart, {len(results)} search result(s) returned")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("create", "verify"):
        print("usage: vectorcheck.py {create|verify} <id_file>")
        sys.exit(2)
    (create if sys.argv[1] == "create" else verify)(sys.argv[2])
