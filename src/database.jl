# database.jl

function init_database(conn::DuckDB.DB)
    # Initialize database tables
    DBInterface.execute(conn, """
        CREATE TABLE IF NOT EXISTS documents (
            id INTEGER PRIMARY KEY,
            content TEXT NOT NULL
        )
    """)
    
    DBInterface.execute(conn, """
        CREATE TABLE IF NOT EXISTS vocabulary (
            word TEXT PRIMARY KEY,
            index INTEGER NOT NULL
        )
    """)
    
    DBInterface.execute(conn, """
        CREATE TABLE IF NOT EXISTS embeddings (
            doc_id INTEGER PRIMARY KEY,
            vector DOUBLE[] NOT NULL,
            FOREIGN KEY (doc_id) REFERENCES documents(id)
        )
    """)
    
    DBInterface.execute(conn, """
        CREATE TABLE IF NOT EXISTS word_embeddings (
            vocab_index INTEGER PRIMARY KEY,
            vector DOUBLE[] NOT NULL
        )
    """)
    
    DBInterface.execute(conn, """
        CREATE TABLE IF NOT EXISTS model_state (
            key TEXT PRIMARY KEY,
            value DOUBLE[] NOT NULL
        )
    """)
end

function load_data(conn::DuckDB.DB, config::TransformerConfig)
    documents = String[]
    vocab = Dict{String,Int}()
    doc_embeddings = Vector{Float32}[]
    
    # Load documents
    result = DBInterface.execute(conn, "SELECT content FROM documents ORDER BY id")
    for row in result
        push!(documents, row.content)
    end
    
    # Load vocabulary
    result = DBInterface.execute(conn, "SELECT word, index FROM vocabulary")
    for row in result
        vocab[row.word] = row.index
    end
    
    # Load document embeddings
    result = DBInterface.execute(conn, "SELECT vector FROM embeddings ORDER BY doc_id")
    for row in result
        push!(doc_embeddings, Float32.(collect(row.vector)))
    end
    
    # Load word embeddings
    word_embeddings = zeros(Float32, config.d_model, max(1, length(vocab)))
    if length(vocab) > 0
        result = DBInterface.execute(conn, "SELECT vocab_index, vector FROM word_embeddings ORDER BY vocab_index")
        for row in result
            word_embeddings[:, row.vocab_index] = Float32.(collect(row.vector))
        end
    end
    
    return documents, vocab, doc_embeddings, word_embeddings
end
