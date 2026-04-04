CREATE OR REPLACE VIEW active_users AS
SELECT id, name, email FROM users WHERE last_active_at > now() - INTERVAL '30 days';
