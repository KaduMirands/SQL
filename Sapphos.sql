-- ============================
-- TIPOS ENUM
-- ============================

CREATE TYPE user_status AS ENUM ('ativa', 'suspensa', 'banida');
CREATE TYPE subscription_status AS ENUM ('ativa', 'expirada', 'cancelada');
CREATE TYPE transaction_status AS ENUM ('concluida', 'falhou', 'pendente');
CREATE TYPE verification_status AS ENUM ('pendente', 'aprovada', 'rejeitada');


-- ============================
-- TABELA: USUÁRIOS
-- ============================

CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    date_of_birth DATE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login_at TIMESTAMP,
    CHECK (EXTRACT(YEAR FROM AGE(CURRENT_DATE, date_of_birth)) >= 18)
);

CREATE TABLE login_history (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL,
    login_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ip_address INET,
    user_agent TEXT,
    CONSTRAINT fk_login_history_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id)
        ON DELETE CASCADE
);


-- ============================
-- REFERÊNCIAS DE ARMAZENAMENTO
-- ============================

CREATE TABLE secure_storage_references (
    ref_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    storage_pointer VARCHAR(255) NOT NULL
);


-- ============================
-- PLANOS
-- ============================

CREATE TABLE plans (
    plan_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_name VARCHAR(100) UNIQUE NOT NULL,
    description TEXT,
    price DECIMAL(10, 2) NOT NULL,
    duration_days INT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);


-- ============================
-- PERFIS (1:1 com users)
-- ============================

CREATE TABLE profiles (
    profile_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE NOT NULL,
    biography TEXT,
    interests TEXT,
    photo_urls JSONB,
    CONSTRAINT fk_profile_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id)
        ON DELETE CASCADE
);


-- ============================
-- ASSINATURAS (1:N com users e plans)
-- ============================

CREATE TABLE subscriptions (
    subscription_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    plan_id UUID NOT NULL,
    status subscription_status DEFAULT 'ativa',
    start_date DATE NOT NULL,
    end_date DATE,
    CONSTRAINT fk_subscription_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_subscription_plan
        FOREIGN KEY (plan_id)
        REFERENCES plans(plan_id)
);


-- ============================
-- REGISTROS DE PAGAMENTO (1:N com subscriptions)
-- ============================

CREATE TABLE payment_records (
    transaction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id UUID NOT NULL,
    amount_paid DECIMAL(10, 2) NOT NULL,
    payment_gateway_token VARCHAR(255) NOT NULL,
    transaction_status transaction_status NOT NULL DEFAULT 'pendente',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_payment_subscription
        FOREIGN KEY (subscription_id)
        REFERENCES subscriptions(subscription_id)
);


-- ============================
-- SUBMISSÕES DE VERIFICAÇÃO
-- ============================

CREATE TABLE verification_submissions (
    submission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    document_ref_id UUID UNIQUE NOT NULL,
    status verification_status NOT NULL DEFAULT 'pendente',
    submitted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMP,
    CONSTRAINT fk_verification_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id),
    CONSTRAINT fk_verification_document
        FOREIGN KEY (document_ref_id)
        REFERENCES secure_storage_references(ref_id)
);


-- ============================
-- MENSAGENS (1:N duplo)
-- ============================

CREATE TABLE messages (
    message_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID NOT NULL,
    recipient_id UUID NOT NULL,
    content TEXT NOT NULL,
    sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_message_sender
        FOREIGN KEY (sender_id)
        REFERENCES users(user_id),
    CONSTRAINT fk_message_recipient
        FOREIGN KEY (recipient_id)
        REFERENCES users(user_id)
);


-- ============================
-- MATCHES (N:N entre users)
-- ============================

CREATE TABLE matches (
    user_id_1 UUID NOT NULL,
    user_id_2 UUID NOT NULL,
    matched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id_1, user_id_2),
    CONSTRAINT fk_matches_user1
        FOREIGN KEY (user_id_1)
        REFERENCES users(user_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_matches_user2
        FOREIGN KEY (user_id_2)
        REFERENCES users(user_id)
        ON DELETE CASCADE
);


-- ============================
-- BLOCK_LIST (N:N entre users)
-- ============================

CREATE TABLE block_list (
    blocker_id UUID NOT NULL,
    blocked_id UUID NOT NULL,
    blocked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (blocker_id, blocked_id),
    CONSTRAINT fk_block_blocker
        FOREIGN KEY (blocker_id)
        REFERENCES users(user_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_block_blocked
        FOREIGN KEY (blocked_id)
        REFERENCES users(user_id)
        ON DELETE CASCADE
);


-- ============================
-- TRIGGERS E FUNÇÕES AUXILIARES
-- ============================

-- Garantir idade mínima
CREATE OR REPLACE FUNCTION check_age()
RETURNS TRIGGER AS $$
BEGIN
    IF EXTRACT(YEAR FROM age(current_date, NEW.date_of_birth)) < 18 THEN
        RAISE EXCEPTION 'Usuário deve ter pelo menos 18 anos.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_age
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION check_age();


-- Definir end_date automaticamente em subscriptions
CREATE OR REPLACE FUNCTION set_subscription_end_date()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.end_date IS NULL THEN
        NEW.end_date := NEW.start_date +
            (SELECT duration_days * INTERVAL '1 day' FROM plans WHERE plan_id = NEW.plan_id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_set_subscription_end_date
BEFORE INSERT ON subscriptions
FOR EACH ROW
EXECUTE FUNCTION set_subscription_end_date();


-- Ativar assinatura ao receber pagamento concluído
CREATE OR REPLACE FUNCTION activate_subscription_on_payment()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.transaction_status = 'concluida' THEN
        UPDATE subscriptions
        SET status = 'ativa'
        WHERE subscription_id = NEW.subscription_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_activate_subscription_on_payment
AFTER INSERT OR UPDATE ON payment_records
FOR EACH ROW
EXECUTE FUNCTION activate_subscription_on_payment();


-- Impedir múltiplas submissões pendentes
CREATE OR REPLACE FUNCTION prevent_multiple_pending_verifications()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM verification_submissions
        WHERE user_id = NEW.user_id
        AND status = 'pendente'
    ) THEN
        RAISE EXCEPTION 'Usuário já possui uma submissão pendente.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_multiple_pending_verifications
BEFORE INSERT ON verification_submissions
FOR EACH ROW
EXECUTE FUNCTION prevent_multiple_pending_verifications();


-- Impedir matches duplicados/invertidos
CREATE OR REPLACE FUNCTION prevent_duplicate_matches()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM matches
        WHERE user_id_1 = NEW.user_id_2
          AND user_id_2 = NEW.user_id_1
    ) THEN
        RAISE EXCEPTION 'Match já existe (invertido).';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_duplicate_matches
BEFORE INSERT ON matches
FOR EACH ROW
EXECUTE FUNCTION prevent_duplicate_matches();


-- Impedir mensagens entre usuários bloqueados
CREATE OR REPLACE FUNCTION prevent_blocked_messages()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM block_list
        WHERE (blocker_id = NEW.sender_id AND blocked_id = NEW.recipient_id)
           OR (blocker_id = NEW.recipient_id AND blocked_id = NEW.sender_id)
    ) THEN
        RAISE EXCEPTION 'Mensagem bloqueada: usuário está na block list.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_blocked_messages
BEFORE INSERT ON messages
FOR EACH ROW
EXECUTE FUNCTION prevent_blocked_messages();


-- ============================
-- PROCEDURES (Stored Procedures)
-- ============================

-- Criar novo usuário
CREATE OR REPLACE PROCEDURE sp_create_user(
    p_username VARCHAR(50),
    p_email VARCHAR(255),
    p_password_hash VARCHAR(255),
    p_date_of_birth DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO users (username, email, password_hash, date_of_birth)
    VALUES (p_username, p_email, p_password_hash, p_date_of_birth);
END;
$$;


-- Criar perfil de usuário
CREATE OR REPLACE PROCEDURE sp_create_profile(
    p_user_id UUID,
    p_biography TEXT,
    p_interests TEXT,
    p_photo_urls JSON
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO profiles (user_id, biography, interests, photo_urls)
    VALUES (p_user_id, p_biography, p_interests, p_photo_urls);
END;
$$;


-- Obter dados completos de um usuário e seu perfil
CREATE OR REPLACE FUNCTION sp_get_user_info(
    p_user_id UUID
)
RETURNS TABLE (
    user_id UUID,
    username VARCHAR,
    email VARCHAR,
    date_of_birth DATE,
    status VARCHAR,
    biography TEXT,
    interests TEXT,
    photo_urls JSON
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT u.user_id, u.username, u.email, u.date_of_birth, u.status,
           p.biography, p.interests, p.photo_urls
    FROM users u
    LEFT JOIN profiles p ON u.user_id = p.user_id
    WHERE u.user_id = p_user_id;
END;
$$;


-- Adicionar um match
CREATE OR REPLACE PROCEDURE add_match(p_user1 UUID, p_user2 UUID)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM matches
        WHERE (user_id_1 = p_user1 AND user_id_2 = p_user2)
           OR (user_id_1 = p_user2 AND user_id_2 = p_user1)
    ) THEN
        INSERT INTO matches (user_id_1, user_id_2)
        VALUES (p_user1, p_user2);
    END IF;
END;
$$;


-- Remover um match
CREATE OR REPLACE PROCEDURE remove_match(p_user1 UUID, p_user2 UUID)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM matches
    WHERE (user_id_1 = p_user1 AND user_id_2 = p_user2)
       OR (user_id_1 = p_user2 AND user_id_2 = p_user1);
END;
$$;


-- Adicionar bloqueio
CREATE OR REPLACE PROCEDURE add_block(p_blocker UUID, p_blocked UUID)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM block_list
        WHERE blocker_id = p_blocker AND blocked_id = p_blocked
    ) THEN
        INSERT INTO block_list (blocker_id, blocked_id)
        VALUES (p_blocker, p_blocked);
    END IF;

    DELETE FROM matches
    WHERE (user_id_1 = p_blocker AND user_id_2 = p_blocked)
       OR (user_id_1 = p_blocked AND user_id_2 = p_blocker);
END;
$$;


-- Remover bloqueio
CREATE OR REPLACE PROCEDURE remove_block(p_blocker UUID, p_blocked UUID)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM block_list
    WHERE blocker_id = p_blocker AND blocked_id = p_blocked;
END;
$$;


-- Renovar assinatura
CREATE OR REPLACE PROCEDURE sp_renew_subscription(p_subscription_id UUID)
LANGUAGE plpgsql AS $$
DECLARE
    v_plan_id UUID;
    v_duration INT;
    v_current_end DATE;
    v_new_end DATE;
BEGIN
    SELECT plan_id, end_date
    INTO v_plan_id, v_current_end
    FROM subscriptions
    WHERE subscription_id = p_subscription_id;

    IF v_plan_id IS NULL THEN
        RAISE EXCEPTION 'Assinatura não encontrada.';
    END IF;

    SELECT duration_days INTO v_duration
    FROM plans WHERE plan_id = v_plan_id;

    IF v_current_end IS NULL OR v_current_end < CURRENT_DATE THEN
        v_new_end := CURRENT_DATE + (v_duration * INTERVAL '1 day');
    ELSE
        v_new_end := v_current_end + (v_duration * INTERVAL '1 day');
    END IF;

    UPDATE subscriptions
    SET end_date = v_new_end, status = 'ativa'
    WHERE subscription_id = p_subscription_id;

    RAISE NOTICE 'Assinatura % renovada até %', p_subscription_id, v_new_end;
END;
$$;


-- Limpar Dados de Usuários Banidos/Suspensos
CREATE OR REPLACE PROCEDURE sp_purge_user_data(p_user_id UUID)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM users
        WHERE user_id = p_user_id
        AND status IN ('banida', 'suspensa')
    ) THEN
        RAISE EXCEPTION 'Usuário % não está banido ou suspenso.', p_user_id;
    END IF;

    UPDATE profiles
    SET biography = NULL, interests = NULL, photo_urls = '[]'::jsonb
    WHERE user_id = p_user_id;

    DELETE FROM verification_submissions WHERE user_id = p_user_id;

    RAISE NOTICE 'Dados sensíveis do usuário % foram anonimizados.', p_user_id;
END;
$$;


-- Atualização em massa dos dados da assinatura
CREATE OR REPLACE PROCEDURE sp_update_expired_subscriptions()
LANGUAGE plpgsql AS $$
DECLARE
    v_count INT;
BEGIN
    UPDATE subscriptions
    SET status = 'expirada'
    WHERE end_date < CURRENT_DATE
      AND status = 'ativa';

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE 'Atualização concluída: % assinaturas marcadas como expiradas.', v_count;
END;
$$;


-- Finalizar Submissão de Verificação
CREATE OR REPLACE PROCEDURE sp_finalize_verification(
    p_submission_id UUID,
    p_final_status verification_status
)
LANGUAGE plpgsql AS $$
DECLARE
    v_doc_ref UUID;
BEGIN
    IF p_final_status NOT IN ('aprovada', 'rejeitada') THEN
        RAISE EXCEPTION 'Status inválido. Use "aprovada" ou "rejeitada".';
    END IF;

    SELECT document_ref_id
    INTO v_doc_ref
    FROM verification_submissions
    WHERE submission_id = p_submission_id;

    IF v_doc_ref IS NULL THEN
        RAISE EXCEPTION 'Submissão % não encontrada.', p_submission_id;
    END IF;

    UPDATE verification_submissions
    SET status = p_final_status,
        reviewed_at = CURRENT_TIMESTAMP
    WHERE submission_id = p_submission_id;

    IF p_final_status = 'aprovada' THEN
        DELETE FROM secure_storage_references
        WHERE ref_id = v_doc_ref;
    END IF;

    RAISE NOTICE 'Submissão % finalizada com status "%".', p_submission_id, p_final_status;
END;
$$;


-- Simulação de Trigger de Login (Verifica status, registra auditoria e atualiza last_login_at)
CREATE OR REPLACE PROCEDURE sp_user_login_action(
    p_user_id UUID,
    p_ip_address INET,
    p_user_agent TEXT DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_status user_status;
BEGIN
    SELECT status INTO v_status
    FROM users
    WHERE user_id = p_user_id;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Usuário % não encontrado.', p_user_id;
    END IF;

    IF v_status <> 'ativa' THEN
        RAISE EXCEPTION 'Login negado. O status do usuário é: %', v_status;
    END IF;

    INSERT INTO login_history (user_id, login_time, ip_address, user_agent)
    VALUES (p_user_id, CURRENT_TIMESTAMP, p_ip_address, p_user_agent);

    UPDATE users
    SET last_login_at = CURRENT_TIMESTAMP
    WHERE user_id = p_user_id;

    RAISE NOTICE 'Login registrado com sucesso para o usuário %', p_user_id;
END;
$$;

--VIEWS --

CREATE OR REPLACE VIEW user_basic AS
SELECT
    user_id,
    username
FROM users;

SELECT * FROM user_basic;

--VIEW 1 --

-- 1) View que mostra o match com os nomes dos usuários
CREATE OR REPLACE VIEW match_view AS
SELECT
    m.user_id_1,
    m.user_id_2,
    u1.username AS user_1,
    u2.username AS user_2,
    m.matched_at
FROM matches m
JOIN users u1 ON u1.user_id = m.user_id_1
JOIN users u2 ON u2.user_id = m.user_id_2;

-- 2) Inserir usuários
BEGIN;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('Jabba the Hutt', 'Jabba@example.com', 'hash_placeholder', '2001-01-01')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('Bobba Fett', 'Bobba@example.com', 'hash_placeholder', '2001-02-02')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('Leia Organo', 'Leia@example.com', 'hash_placeholder', '2001-01-01')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('Ahsoka Tano', 'Ahsoka@example.com', 'hash_placeholder', '2001-02-02')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('Luke Skywalker', 'Luke@example.com', 'hash_placeholder', '2001-01-01')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('Chewbacca', 'Chewbacca@example.com', 'hash_placeholder', '2001-02-02')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('C3P0', 'C3P0@example.com', 'hash_placeholder', '2001-02-02')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (username, email, password_hash, date_of_birth)
VALUES ('R2D2', 'R2D2@example.com', 'hash_placeholder', '2001-02-02')
ON CONFLICT (username) DO NOTHING;




-- 3) Inserir o match entre apenas se não existir (evita duplicados/invertidos)
INSERT INTO matches (user_id_1, user_id_2)
SELECT u1.user_id, u2.user_id
FROM users u1
CROSS JOIN users u2
WHERE u1.username = 'C3P0'
  AND u2.username = 'R2D2'
  AND NOT EXISTS (
      SELECT 1
      FROM matches m
      WHERE (m.user_id_1 = u1.user_id AND m.user_id_2 = u2.user_id)
         OR (m.user_id_1 = u2.user_id AND m.user_id_2 = u1.user_id)
  );

COMMIT;

-- 4) Conferir o resultado pela view
SELECT * FROM match_view;



-- VIEW 2: Planos Premium--

CREATE OR REPLACE VIEW users_with_premium AS
SELECT
    u.user_id,
    u.username,
    u.email,
    s.subscription_id,
    p.plan_id,
    p.plan_name,
    s.start_date,
    s.end_date
FROM subscriptions s
JOIN plans p ON p.plan_id = s.plan_id
JOIN users u ON u.user_id = s.user_id
WHERE s.status = 'ativa'
  AND p.plan_name ILIKE '%premium%'
  AND (s.end_date IS NULL OR s.end_date >= CURRENT_DATE);

  -- 1) Criar plano "Premium"
--    Se já existir, atualiza price/duration e retorna plan_id
INSERT INTO plans (plan_name, description, price, duration_days)
VALUES ('Premium', 'Plano Premium mensal', 29.90, 30)
ON CONFLICT (plan_name) DO UPDATE
  SET description = EXCLUDED.description,
      price = EXCLUDED.price,
      duration_days = EXCLUDED.duration_days
RETURNING plan_id;



-- 2) Criar assinaturas para os usuários apontando para o plano Premium
--    Usamos subselects para pegar os ids dinamicamente.

-- Usuario 1
INSERT INTO subscriptions (user_id, plan_id, start_date)
SELECT u.user_id, p.plan_id, CURRENT_DATE
FROM users u, plans p
WHERE u.username = 'Bobba Fett' AND p.plan_name = 'Premium'
AND NOT EXISTS (
  SELECT 1 FROM subscriptions s
  WHERE s.user_id = u.user_id
    AND s.plan_id = p.plan_id
    AND s.status = 'ativa'
);

-- Usuario 2
INSERT INTO subscriptions (user_id, plan_id, start_date)
SELECT u.user_id, p.plan_id, CURRENT_DATE
FROM users u, plans p
WHERE u.username = 'Luke Skywalker' AND p.plan_name = 'Premium'
AND NOT EXISTS (
  SELECT 1 FROM subscriptions s
  WHERE s.user_id = u.user_id
    AND s.plan_id = p.plan_id
    AND s.status = 'ativa'
);


SELECT * FROM users_with_premium;

-- VIEW 3 Usuarios blockeados --


-- 1) View: usuários que bloquearam outros usuários
CREATE OR REPLACE VIEW users_who_blocked AS
SELECT
    bl.blocker_id,
    bl.blocked_id,
    blocker.username AS blocker_username,
    blocked.username AS blocked_username,
    bl.blocked_at
FROM block_list bl
JOIN users blocker ON blocker.user_id = bl.blocker_id
JOIN users blocked ON blocked.user_id = bl.blocked_id;



-- 2) Inserir bloqueios
INSERT INTO block_list (blocker_id, blocked_id, blocked_at)
SELECT a.user_id, b.user_id, CURRENT_TIMESTAMP
FROM users a, users b
WHERE a.username = 'Leia Organo' AND b.username = 'Luke Skywalker'
ON CONFLICT DO NOTHING;



-- 3) Conferir resultado pela view
SELECT * FROM users_who_blocked;
