BEGIN;

CREATE TABLE IF NOT EXISTS inventory (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku VARCHAR(32) NOT NULL UNIQUE,
    name VARCHAR(120) NOT NULL,
    category VARCHAR(60) NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity BETWEEN 0 AND 1000000),
    unit VARCHAR(20) NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO inventory (sku, name, category, quantity, unit) VALUES
    ('DR-APPLE-001', 'Orchard apples', 'Fruit', 42, 'kg'),
    ('DR-PEAR-001', 'Conference pears', 'Fruit', 18, 'kg'),
    ('DR-CARROT-001', 'Market carrots', 'Vegetables', 35, 'kg'),
    ('DR-TOMATO-001', 'Heirloom tomatoes', 'Vegetables', 24, 'kg'),
    ('DR-POTATO-001', 'Harvest potatoes', 'Vegetables', 60, 'kg'),
    ('DR-PUMPKIN-001', 'Autumn pumpkins', 'Vegetables', 12, 'pieces'),
    ('DR-HONEY-001', 'Wildflower honey', 'Pantry', 15, 'jars'),
    ('DR-JAM-001', 'Apricot preserves', 'Pantry', 9, 'jars')
ON CONFLICT (sku) DO NOTHING;

WITH products (slot, name, category, unit) AS (
    VALUES
        (0, 'Orchard apples', 'Fruit', 'kg'),
        (1, 'Conference pears', 'Fruit', 'kg'),
        (2, 'Market carrots', 'Vegetables', 'kg'),
        (3, 'Heirloom tomatoes', 'Vegetables', 'kg'),
        (4, 'Harvest potatoes', 'Vegetables', 'kg'),
        (5, 'Autumn pumpkins', 'Vegetables', 'pieces'),
        (6, 'Wildflower honey', 'Pantry', 'jars'),
        (7, 'Apricot preserves', 'Pantry', 'jars')
)
INSERT INTO inventory (sku, name, category, quantity, unit)
SELECT
    'DR-DEMO-' || lpad(lot.number::text, 3, '0'),
    products.name || ' - lot ' || lpad(lot.number::text, 3, '0'),
    products.category,
    ((lot.number - 1) * 17) % 101,
    products.unit
FROM generate_series(1, 100) AS lot(number)
JOIN products ON products.slot = (lot.number - 1) % 8
ORDER BY lot.number
ON CONFLICT (sku) DO NOTHING;

COMMIT;
