-- Run once after production_schema.sql on a new PRODUÇÃO project.
-- The application uploads and signs product files through its server.
INSERT INTO storage.buckets (id, name, public)
VALUES ('product-files', 'product-files', false)
ON CONFLICT (id) DO NOTHING;
