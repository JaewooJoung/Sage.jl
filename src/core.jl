#= Constructor: Create a new JJAI instance with specified database path and configuration
Parameters:
- db_path: Path to DuckDB database file (default: "Snild.duckdb")
- config: TransformerConfig instance with model parameters (default: DEFAULT_CONFIG)
Returns: JJAI instance
=#
function JJAI(db_path::String="Snild.duckdb", config::TransformerConfig=DEFAULT_CONFIG)
    try
        conn = DBInterface.connect(DuckDB.DB, db_path)
        init_database(conn)

        # Initialize transformer components
        positional_enc = positional_encoding(config.max_seq_length, config.d_model)

        # Load existing data
        documents, vocab, doc_embeddings, word_embeddings = load_data(conn, config)

        JJAI(
            documents,
            doc_embeddings,
            vocab,
            word_embeddings,
            positional_enc,
            config,
            Float32[],
            Dict{String,Any}(),
            db_path,
            conn
        )
    catch e
        @error "Failed to initialize JJAI" exception=e
        rethrow(e)
    end
end

#= Helper function for vector normalization
Parameters:
- v: Input vector of type Float32
Returns: Normalized vector with numerical stability
=#
normalize(v::Vector{Float32}) = v / (norm(v) + eps(Float32))

#= Helper function to wrap database transactions
Parameters:
- f: Function containing database operations
- conn: Database connection
Returns: Result of function f
=#
function with_transaction(f, conn)
    DBInterface.execute(conn, "BEGIN TRANSACTION")
    try
        result = f()
        DBInterface.execute(conn, "COMMIT")
        return result
    catch e
        DBInterface.execute(conn, "ROLLBACK")
        rethrow(e)
    end
end

#= Tokenize and encode text into embeddings
Parameters:
- ai: JJAI instance
- text: Input text string
Returns: Matrix of embeddings with word vectors and positional encoding
=#
function encode_text(ai::JJAI, text::String)
    words = split(lowercase(text))
    seq_length = min(length(words), ai.config.max_seq_length)

    # Initialize empty embedding matrix
    embeddings = zeros(Float32, ai.config.d_model, seq_length)

    # Add word embeddings and positional encodings
    for (i, word) in enumerate(words[1:seq_length])
        if haskey(ai.vocab, word)
            word_idx = ai.vocab[word]
            embeddings[:, i] = ai.word_embeddings[:, word_idx]
        end
        embeddings[:, i] += ai.positional_enc[i, :]
    end

    return embeddings
end

#= Apply transformer encoding to embeddings
Parameters:
- ai: JJAI instance
- embeddings: Input embedding matrix
Returns: Encoded vector representation
=#
function transformer_encode(ai::JJAI, embeddings::Matrix{Float32})
    # Multi-head attention
    attn_output = multi_head_attention(
        embeddings,  # Q
        embeddings,  # K
        embeddings,  # V
        ai.config.n_head,
        ai.config.d_model
    )

    # Add & Norm
    attn_output = attn_output + embeddings
    attn_output = layer_norm(attn_output)

    # Feed-forward network
    ff_output = feed_forward(attn_output, ai.config.d_ff)

    # Add & Norm
    ff_output = ff_output + attn_output
    ff_output = layer_norm(ff_output)

    # Return mean pooling of the sequence
    return vec(mean(ff_output, dims=2))
end

#= Add new text to knowledge base
Parameters:
- ai: JJAI instance
- text: Text to learn
Side effects:
- Updates vocabulary
- Updates word embeddings
- Stores document and embeddings in database
=#
function learn!(ai::JJAI, text::String)
    # Add to documents
    push!(ai.documents, text)

    # Update vocabulary
    words = split(lowercase(text))
    vocab_changed = false
    for word in words
        if !haskey(ai.vocab, word)
            vocab_changed = true
            ai.vocab[word] = length(ai.vocab) + 1

            DBInterface.execute(ai.conn, """
                INSERT INTO vocabulary (word, index) VALUES (?, ?)
            """, (word, ai.vocab[word]))
        end
    end

    # Initialize/update word embeddings if vocabulary size changed
    vocab_size = length(ai.vocab)
    if vocab_changed || isempty(ai.word_embeddings)
        if isempty(ai.word_embeddings)
            ai.word_embeddings = randn(Float32, ai.config.d_model, vocab_size)

            for (word, idx) in ai.vocab
                vector_doubles = Float64.(ai.word_embeddings[:, idx])
                vector_list = "ARRAY[" * join(string.(vector_doubles), ",") * "]::DOUBLE[]"
                DBInterface.execute(ai.conn, """
                    INSERT INTO word_embeddings (vocab_index, vector)
                    VALUES (?, $vector_list)
                """, (idx,))
            end
        else
            old_size = size(ai.word_embeddings, 2)
            new_embeddings = zeros(Float32, ai.config.d_model, vocab_size)
            new_embeddings[:, 1:old_size] = ai.word_embeddings

            if vocab_size > old_size
                new_embeddings[:, (old_size+1):end] = randn(Float32, ai.config.d_model, vocab_size - old_size)

                for idx in (old_size+1):vocab_size
                    vector_doubles = Float64.(new_embeddings[:, idx])
                    vector_list = "ARRAY[" * join(string.(vector_doubles), ",") * "]::DOUBLE[]"
                    DBInterface.execute(ai.conn, """
                        INSERT INTO word_embeddings (vocab_index, vector)
                        VALUES (?, $vector_list)
                    """, (idx,))
                end
            end
            ai.word_embeddings = new_embeddings
        end
    end

    # Encode and transform the text
    text_embeddings = encode_text(ai, text)
    doc_embedding = transformer_encode(ai, text_embeddings)
    push!(ai.doc_embeddings, doc_embedding)

    # Get next document ID and save to database
    result = DBInterface.execute(ai.conn, "SELECT COALESCE(MAX(id), 0) + 1 FROM documents")
    next_id = first(result)[1]

    with_transaction(ai.conn) do
        DBInterface.execute(ai.conn, """
            INSERT INTO documents (id, content) VALUES (?, ?)
        """, (next_id, text))

        vector_doubles = Float64.(doc_embedding)
        vector_list = "ARRAY[" * join(string.(vector_doubles), ",") * "]::DOUBLE[]"

        DBInterface.execute(ai.conn, """
            INSERT INTO embeddings (doc_id, vector)
            VALUES (?, $vector_list)
        """, (next_id,))
    end
end

#= Find most relevant response to question
Parameters:
- ai: JJAI instance
- question: Input question string
Returns: Most relevant response with confidence score
=#
function answer(ai::JJAI, question::String)
    if isempty(ai.documents)
        return "No knowledge yet."
    end

    # Preprocess question to normalize it
    question = lowercase(strip(question))
    question_words = Set(split(question))

    # Initialize variables for finding best match
    best_score = -1.0
    best_doc = ""
    best_match_score = 0.0

    # First pass: Look for word overlap matches
    for doc in ai.documents
        doc_lower = lowercase(doc)
        doc_words = Set(split(doc_lower))

        # Calculate word overlap score
        total_matches = length(intersect(question_words, doc_words))
        match_score = total_matches / length(question_words)

        if match_score > best_match_score
            best_match_score = match_score
            best_doc = doc
        end
    end

    # If we found a good word overlap match, use it
    if best_match_score > 0.2
        return "($(@sprintf("%.2f", best_match_score * 100))% relevant) $best_doc"
    end

    # Fall back to embedding similarity if no good direct matches
    question_embeddings = encode_text(ai, question)
    question_embedding = transformer_encode(ai, question_embeddings)

    for (doc, embed) in zip(ai.documents, ai.doc_embeddings)
        q_norm = normalize(question_embedding)
        e_norm = normalize(embed)
        score = dot(q_norm, e_norm)

        if score > best_score
            best_score = score
            best_doc = doc
        end
    end

    if best_score > 0.3
        return "($(@sprintf("%.2f", best_score * 100))% confident) $best_doc"
    else
        return "I don't have enough information to answer that question confidently."
    end
end

#= Clear all stored knowledge
Parameters:
- ai: JJAI instance
Side effects:
- Drops and recreates all tables
- Clears in-memory data
=#
function reset_knowledge!(ai::JJAI)
    with_transaction(ai.conn) do
        # Drop tables in correct order
        DBInterface.execute(ai.conn, "DROP TABLE IF EXISTS embeddings")
        DBInterface.execute(ai.conn, "DROP TABLE IF EXISTS word_embeddings")
        DBInterface.execute(ai.conn, "DROP TABLE IF EXISTS model_state")
        DBInterface.execute(ai.conn, "DROP TABLE IF EXISTS vocabulary")
        DBInterface.execute(ai.conn, "DROP TABLE IF EXISTS documents")

        # Recreate tables
        DBInterface.execute(ai.conn, """
            CREATE TABLE documents (
                id INTEGER PRIMARY KEY,
                content TEXT NOT NULL
            )
        """)

        DBInterface.execute(ai.conn, """
            CREATE TABLE vocabulary (
                word TEXT PRIMARY KEY,
                index INTEGER NOT NULL
            )
        """)

        DBInterface.execute(ai.conn, """
            CREATE TABLE embeddings (
                doc_id INTEGER PRIMARY KEY,
                vector DOUBLE[] NOT NULL,
                FOREIGN KEY (doc_id) REFERENCES documents(id)
            )
        """)

        DBInterface.execute(ai.conn, """
            CREATE TABLE word_embeddings (
                vocab_index INTEGER PRIMARY KEY,
                vector DOUBLE[] NOT NULL
            )
        """)

        DBInterface.execute(ai.conn, """
            CREATE TABLE model_state (
                key TEXT PRIMARY KEY,
                value DOUBLE[] NOT NULL
            )
        """)
    end

    # Clear in-memory data
    empty!(ai.documents)
    empty!(ai.doc_embeddings)
    empty!(ai.vocab)
    ai.word_embeddings = zeros(Float32, ai.config.d_model, 1)
end

#= Cleanup resources
Parameters:
- ai: JJAI instance
Side effects:
- Forces checkpoint
- Closes database connection
=#
function cleanup!(ai::JJAI)
    if ai.conn !== nothing
        try
            # Force a checkpoint to ensure all data is written to disk
            DBInterface.execute(ai.conn, "PRAGMA force_checkpoint")
            close(ai.conn)
        catch e
            # If there's an error during cleanup, at least close the connection
            @warn "Error during cleanup" exception=e
            close(ai.conn)
        end
    end
end
