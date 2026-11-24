#!/usr/bin/env python3
"""
OGX Chat and Embeddings Demo with S3-Backed File Storage

This script demonstrates how to:
1. Authenticate with Keycloak to get a JWT token
2. Upload files to FileAPI (stored in MinIO/S3)
3. Retrieve file contents from S3
4. List available models (inference and embedding)
5. Generate embeddings for documents
6. Create vector stores and insert embeddings
7. Perform semantic search queries
8. Generate answers using chat completions with RAG

Usage:
    uv run demos/rag/demo.py [OGX_URL] [KEYCLOAK_URL] [USERNAME] [PASSWORD] [CLIENT_SECRET]

The script reads configuration from (in order): command line args,
environment variables. All arguments are optional if set as env vars.

Example with no arguments (reads from environment):
    uv run demos/rag/demo.py

Example with URLs only:
    uv run demos/rag/demo.py https://ogx-distribution.apps.example.com \
        https://keycloak.apps.example.com

Example with full authentication:
    uv run demos/rag/demo.py https://ogx-distribution.apps.example.com \
        https://keycloak.apps.example.com \
        developer dev123

If Keycloak parameters are not provided, the script will run without authentication.

Note: This demo uses the OGX FileAPI with MinIO S3 backend for document storage
and the vector-io API with Milvus for vector storage.
"""

import sys
import requests
import os

from typing import List, Dict, Any, Optional
from pathlib import Path

# Add project root to path for imports
PROJECT_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from demos.common.utils import get_keycloak_token, load_demo_config


class OGXDemo:
    def __init__(self, base_url: str, keycloak_url: Optional[str] = None,
                 username: Optional[str] = None, password: Optional[str] = None,
                 client_secret: Optional[str] = None,
                 inference_model: str = "vllm-inference/llama-3-2-3b",
                 embedding_model: str = "vllm-embedding/nomic-embed-text-v1.5",
                 embedding_dimension: int = 768):
        self.base_url = base_url.rstrip('/')
        self.keycloak_url = keycloak_url.rstrip('/') if keycloak_url else None
        self.username = username
        self.password = password
        self.client_secret = client_secret
        self.inference_model = inference_model
        self.embedding_model = embedding_model
        self.embedding_dimension = embedding_dimension
        self.session = requests.Session()
        self.session.verify = True  # Enable SSL verification

        # Get token if Keycloak credentials are provided
        if self.keycloak_url and self.username and self.password and self.client_secret:
            self.authenticate()

    def authenticate(self) -> bool:
        """Get JWT token from Keycloak"""
        try:
            access_token = get_keycloak_token(
                self.keycloak_url,
                self.username,
                self.password,
                self.client_secret
            )
            self.session.headers.update({'Authorization': f'Bearer {access_token}'})
            return True
        except Exception as e:
            print(f"✗ Authentication failed: {e}")
            return False

    def check_health(self) -> bool:
        """Check if OGX API is healthy"""
        try:
            response = self.session.get(f"{self.base_url}/v1/health", timeout=10)
            response.raise_for_status()
            print(f"✓ OGX is healthy")
            return True
        except Exception as e:
            print(f"✗ Health check failed: {e}")
            return False

    def upload_file(self, file_path: str, purpose: str = "assistants") -> Optional[str]:
        """Upload a file to FileAPI (stored in S3/MinIO) and return the file ID"""
        try:
            with open(file_path, 'rb') as f:
                files = {'file': (os.path.basename(file_path), f)}
                data = {'purpose': purpose}
                response = self.session.post(f"{self.base_url}/v1/files", files=files, data=data)
                response.raise_for_status()
                result = response.json()
                file_id = result.get('id')
                print(f"  ✓ Uploaded: {os.path.basename(file_path)} (ID: {file_id})")
                return file_id
        except Exception as e:
            print(f"  ✗ Upload failed for {file_path}: {e}")
            return None

    def get_file_content(self, file_id: str) -> Optional[str]:
        """Retrieve file content from FileAPI (reads from S3/MinIO)"""
        try:
            response = self.session.get(f"{self.base_url}/v1/files/{file_id}/content")
            response.raise_for_status()
            return response.text
        except Exception as e:
            print(f"  ✗ Failed to retrieve file {file_id}: {e}")
            return None

    def list_models(self) -> List[Dict[str, Any]]:
        """List available models"""
        try:
            response = self.session.get(f"{self.base_url}/v1/models")
            response.raise_for_status()
            result = response.json()
            models = result.get('data', [])
            print(f"\n✓ Available models:")
            for model in models:
                model_id = model.get('id', 'unknown')
                model_type = model.get('custom_metadata', {}).get('model_type', 'unknown')
                print(f"  - {model_id} ({model_type})")
            return models
        except Exception as e:
            print(f"✗ Failed to list models: {e}")
            return []

    def generate_embeddings(self, texts: List[str], model: str = None) -> List[List[float]]:
        """Generate embeddings for a list of texts"""
        try:
            payload = {
                "input": texts,
                "model": model or self.embedding_model
            }
            response = self.session.post(
                f"{self.base_url}/v1/embeddings",
                json=payload,
                headers={"Content-Type": "application/json"}
            )

            if response.status_code == 200:
                result = response.json()
                embeddings = [item['embedding'] for item in result['data']]
                print(f"\n✓ Generated embeddings for {len(texts)} texts")
                return embeddings
            else:
                print(f"✗ Failed to generate embeddings: {response.status_code}")
                print(f"  Response: {response.text}")
                return []
        except Exception as e:
            print(f"✗ Error generating embeddings: {e}")
            return []

    def create_vector_store(self, name: str, embedding_dimension: int = None, provider_id: str = "milvus-remote") -> Optional[str]:
        """Create a vector store using vector_io API. Returns the vector store ID."""
        try:
            payload = {
                "vector_store_id": name,
                "embedding_model": self.embedding_model,
                "embedding_dimension": embedding_dimension or self.embedding_dimension,
                "provider_id": provider_id
            }
            response = self.session.post(
                f"{self.base_url}/v1/vector_stores",
                json=payload,
                headers={"Content-Type": "application/json"}
            )

            if response.status_code in [200, 201]:
                result = response.json()
                vector_store_id = result.get('id')
                print(f"✓ Created vector store: {vector_store_id}")
                return vector_store_id
            else:
                print(f"✗ Failed to create vector store: {response.status_code}")
                print(f"  Response: {response.text}")
                return None
        except Exception as e:
            print(f"✗ Error creating vector store: {e}")
            return None

    def insert_vectors(self, vector_store_id: str, documents: List[Dict[str, Any]], embeddings: List[List[float]]) -> bool:
        """Insert document embeddings into vector store"""
        try:
            # Prepare chunks with embeddings and metadata
            chunks = []
            for i, (doc, embedding) in enumerate(zip(documents, embeddings)):
                chunks.append({
                    "chunk_id": f"{doc['metadata']['source']}_{i}",
                    "content": doc['content'],
                    "embedding": embedding,
                    "embedding_model": self.embedding_model,
                    "embedding_dimension": len(embedding),
                    "chunk_metadata": {
                        "source": doc['metadata']['source'],
                        "topic": doc['metadata']['topic']
                    }
                })

            payload = {
                "vector_store_id": vector_store_id,
                "chunks": chunks
            }

            response = self.session.post(
                f"{self.base_url}/v1/vector-io/insert",
                json=payload,
                headers={"Content-Type": "application/json"}
            )

            # 204 No Content is a valid success response for insert operations
            if response.status_code in [200, 201, 204]:
                print(f"✓ Inserted {len(chunks)} vectors into {vector_store_id}")
                return True
            else:
                print(f"✗ Failed to insert vectors: {response.status_code}")
                print(f"  Response: {response.text}")
                return False
        except Exception as e:
            print(f"✗ Error inserting vectors: {e}")
            return False

    def query_vectors(self, vector_store_id: str, query_text: str, top_k: int = 3) -> List[Dict[str, Any]]:
        """Query vector store for similar documents"""
        try:
            payload = {
                "vector_store_id": vector_store_id,
                "query": query_text,
                "params": {"k": top_k}
            }

            response = self.session.post(
                f"{self.base_url}/v1/vector-io/query",
                json=payload,
                headers={"Content-Type": "application/json"}
            )

            if response.status_code == 200:
                result = response.json()
                # Extract chunks from response
                chunks = result.get('chunks', [])
                scores = result.get('scores', [])

                # If scores are in a separate array, attach them to chunks
                if scores and len(scores) == len(chunks):
                    for i, chunk in enumerate(chunks):
                        chunk['score'] = scores[i]

                return chunks
            else:
                print(f"✗ Failed to query vectors: {response.status_code}")
                print(f"  Response: {response.text}")
                return []
        except Exception as e:
            print(f"✗ Error querying vectors: {e}")
            return []

    def search_vector_store(self, vector_store_id: str, query_text: str, top_k: int = 3) -> List[Dict[str, Any]]:
        """Search a vector store via the OpenAI-compatible endpoint."""
        try:
            payload = {"query": query_text, "max_num_results": top_k}

            response = self.session.post(
                f"{self.base_url}/v1/vector_stores/{vector_store_id}/search",
                json=payload,
                headers={"Content-Type": "application/json"}
            )

            if response.status_code == 200:
                return response.json().get('data', [])
            else:
                print(f"✗ Failed to search vector store: {response.status_code}")
                print(f"  Response: {response.text}")
                return []
        except Exception as e:
            print(f"✗ Error searching vector store: {e}")
            return []

    def chat_completion(self, query: str, context: str = "", model: str = None) -> str:
        """Generate a completion using the chat endpoint"""
        try:
            messages = []
            if context:
                messages.append({
                    "role": "system",
                    "content": f"Use the following context to answer the question:\n\n{context}"
                })
            messages.append({
                "role": "user",
                "content": query
            })

            payload = {
                "model": model or self.inference_model,
                "messages": messages,
                "max_tokens": 512,
                "temperature": 0.7
            }

            response = self.session.post(
                f"{self.base_url}/v1/chat/completions",
                json=payload,
                headers={"Content-Type": "application/json"}
            )

            if response.status_code == 200:
                result = response.json()
                answer = result.get('choices', [{}])[0].get('message', {}).get('content', '')
                return answer
            else:
                print(f"✗ Chat completion failed: {response.status_code}")
                print(f"  Response: {response.text}")
                return ""
        except Exception as e:
            print(f"✗ Error in chat completion: {e}")
            return ""


def main():
    # Load configuration from command line args, secrets file, or environment variables
    config = load_demo_config()

    ogx_url = config['ogx_url']
    keycloak_url = config['keycloak_url']
    username = config['username']
    password = config['password']
    client_secret = config['client_secret']

    # Validate that we have at least the OGX URL
    if not ogx_url:
        print("Error: OGX_URL is required")
        print("\nUsage: uv run demos/rag/demo.py [OGX_URL] [KEYCLOAK_URL] [USERNAME] [PASSWORD] [CLIENT_SECRET]")
        print("\nExamples:")
        print("  # Run with configuration from environment:")
        print("  uv run demos/rag/demo.py")
        print("\n  # Run with explicit URLs:")
        print("  uv run demos/rag/demo.py https://ogx-distribution.apps.example.com \\")
        print("      https://keycloak.apps.example.com")
        print("\n  # Run with full authentication:")
        print("  uv run demos/rag/demo.py https://ogx-distribution.apps.example.com \\")
        print("      https://keycloak.apps.example.com developer dev123")
        print("\nNote: Run ./test.sh to auto-load credentials from the K8s cluster")
        sys.exit(1)

    print("=" * 60)
    print("OGX Chat and Embeddings Demo")
    print("=" * 60)
    print(f"\nConnecting to: {ogx_url}")
    if keycloak_url:
        print(f"Keycloak URL: {keycloak_url}")
        print(f"Username: {username}")

    # Initialize the demo
    demo = OGXDemo(ogx_url, keycloak_url, username, password, client_secret,
                   inference_model=config['inference_model'],
                   embedding_model=config['embedding_model'],
                   embedding_dimension=config['embedding_dimension'])

    # Check health
    if not demo.check_health():
        print("\n✗ Cannot connect to OGX. Please check the URL and try again.")
        sys.exit(1)

    # List available models
    models = demo.list_models()

    # Load sample document from fixtures
    knowledge_base_file = PROJECT_ROOT / "demos" / "fixtures" / "knowledge_base.txt"

    if not knowledge_base_file.exists():
        print(f"\n✗ Sample document not found: {knowledge_base_file}")
        print("  Please create knowledge_base.txt in demos/fixtures/")
        sys.exit(1)

    print(f"\nFound sample knowledge base document: {knowledge_base_file.name}")

    # Step 1: Upload file to FileAPI (stored in MinIO S3)
    print("\n" + "=" * 60)
    print("Step 1: Uploading Document to FileAPI (MinIO S3 Backend)")
    print("=" * 60)

    file_id = demo.upload_file(str(knowledge_base_file))
    if not file_id:
        print("\n✗ Failed to upload document. Exiting.")
        sys.exit(1)

    print(f"\n✓ Successfully uploaded document to MinIO S3")
    print("  File is stored in the 'ogx-files' bucket")

    # Step 2: Retrieve file content from S3
    print("\n" + "=" * 60)
    print("Step 2: Retrieving File Content from S3")
    print("=" * 60)

    print(f"  Retrieving: {knowledge_base_file.name}")
    content = demo.get_file_content(file_id)
    if not content:
        print("\n✗ Failed to retrieve document from S3. Exiting.")
        sys.exit(1)

    print(f"\n✓ Retrieved document from S3 storage ({len(content)} characters)")

    # Step 3: Split content into document chunks for RAG
    print("\n" + "=" * 60)
    print("Step 3: Chunking Document for Knowledge Base")
    print("=" * 60)

    # Split by paragraphs (double newline)
    paragraphs = [p.strip() for p in content.split('\n\n') if p.strip()]

    # Define metadata for each chunk based on content
    chunk_metadata = [
        {"source": "rhoai_overview", "topic": "platform"},
        {"source": "ogx_intro", "topic": "framework"},
        {"source": "rag_explanation", "topic": "rag"},
        {"source": "vector_db_info", "topic": "vector_database"},
        {"source": "rhoai_features", "topic": "platform"}
    ]

    documents = []
    for i, paragraph in enumerate(paragraphs):
        metadata = chunk_metadata[i] if i < len(chunk_metadata) else {"source": f"chunk_{i}", "topic": "general"}
        metadata["file_id"] = file_id
        metadata["storage"] = "s3-minio"
        documents.append({
            "content": paragraph,
            "metadata": metadata
        })

    print(f"\n✓ Split document into {len(documents)} chunks for knowledge base")

    print("\n" + "=" * 60)
    print("Step 4: Creating Knowledge Base Embeddings")
    print("=" * 60)
    print(f"\nDocuments in knowledge base (from S3):")
    for i, doc in enumerate(documents, 1):
        preview = doc['content'][:80] + "..." if len(doc['content']) > 80 else doc['content']
        source = doc['metadata'].get('source', 'unknown')
        print(f"  {i}. [{source}] {preview}")

    # Generate embeddings for all documents
    doc_texts = [doc['content'] for doc in documents]
    doc_embeddings = demo.generate_embeddings(doc_texts)

    if not doc_embeddings:
        print("\n✗ Failed to generate embeddings. Exiting.")
        sys.exit(1)

    # Create vector store and insert document embeddings
    print("\n" + "=" * 60)
    print("Step 5: Setting up Vector Store (Milvus)")
    print("=" * 60)

    vector_store_id = demo.create_vector_store("rag-demo-kb")
    if not vector_store_id:
        print("\n✗ Failed to create vector store. Exiting.")
        sys.exit(1)

    if not demo.insert_vectors(vector_store_id, documents, doc_embeddings):
        print("\n✗ Failed to insert vectors. Exiting.")
        sys.exit(1)

    # Query examples
    queries = [
        "What is Red Hat OpenShift AI?",
        "How does RAG work?",
        "What is a vector database used for?",
        "What tools does OpenShift AI support?"
    ]

    print("\n" + "=" * 60)
    print("Step 6: RAG Pipeline - Semantic Search and Q&A")
    print("=" * 60)

    for i, query in enumerate(queries, 1):
        print(f"\n{'-' * 60}")
        print(f"Query {i}: {query}")
        print(f"{'-' * 60}")

        # Query vector store for similar documents (API generates embedding internally)
        results = demo.query_vectors(vector_store_id, query, top_k=3)

        if not results:
            print("\n✗ No results found")
            continue

        print(f"\nMost relevant documents:")
        for j, chunk in enumerate(results, 1):
            chunk_metadata = chunk.get('chunk_metadata', {})
            source = chunk_metadata.get('source', 'unknown')
            score = chunk.get('score', 0.0)
            print(f"  {j}. {source} (similarity: {score:.3f})")

        # Build context from top results
        context = "\n\n".join([chunk.get('content', '') for chunk in results[:2]])

        # Generate answer using chat completions
        print(f"\nGenerating answer with chat completions...")
        answer = demo.chat_completion(query, context)
        if answer:
            print(f"\nAnswer: {answer}")
        else:
            print("\n✗ Failed to generate answer")

    print("\n" + "=" * 60)
    print("✅ Demo Complete!")
    print("=" * 60)
    print("\nThis demo showed the complete S3-backed RAG pipeline:")
    print("  1. ✓ Uploaded document to FileAPI (stored in MinIO S3)")
    print("  2. ✓ Retrieved file content from S3 storage")
    print("  3. ✓ Chunked document into multiple text segments")
    print("  4. ✓ Generated embeddings for document chunks")
    print("  5. ✓ Created a vector store using OGX vector_io API")
    print("  6. ✓ Inserted vectors into Milvus for persistent storage")
    print("  7. ✓ Semantic search using Milvus vector similarity")
    print("  8. ✓ Context-aware question answering with chat completions")
    print("\nVerification:")
    print("  - Check MinIO console to see uploaded file in 'ogx-files' bucket")
    print("  - File is persistently stored in S3 and can be reused")
    print("  - Vector embeddings are indexed in Milvus for fast retrieval")
    print("\nTo run your own queries, modify the 'queries' or 'knowledge_base.txt' in scripts/.")


if __name__ == "__main__":
    main()
