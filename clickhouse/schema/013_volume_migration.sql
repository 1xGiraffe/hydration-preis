-- ============================================================================
-- VOLUME MIGRATION: Upgrade OHLC Database to OHLCV
-- ============================================================================
--
-- PURPOSE:
-- This migration script upgrades an existing ClickHouse database from OHLC (price-only)
-- to OHLCV (price + volume) schema. It adds volume tracking columns to the prices table
-- and recreates all materialized views to include volume aggregation.
--
-- SAFETY:
-- All operations use idempotent guards (IF NOT EXISTS / IF EXISTS) to ensure the migration
-- can be safely run multiple times without errors. If the migration is interrupted or
-- partially applied, re-running the script will complete the upgrade safely.
--
-- DATA PRESERVATION:
-- Existing OHLC candle data is preserved through the DROP/ALTER/CREATE pattern:
--   1. DROP VIEW - Removes the old OHLC view definition (target table data is preserved)
--   2. ALTER TABLE - Adds volume columns to target table (metadata-only, instant)
--   3. CREATE VIEW - Recreates as OHLCV view with volume aggregation
--
-- Dropping a materialized view does NOT affect the target table. Historical candle data
-- remains intact. Only new price inserts after migration will populate volume fields
-- (existing candles will have volume=0 until backfilled).
--
-- EXECUTION ORDER:
-- This script must run AFTER the base schema files (001-012) have been applied at least once.
-- It assumes the database already has:
--   - price_data.prices table (without volume columns)
--   - price_data.ohlc_* target tables (without volume aggregate columns)
--   - price_data.ohlc_*_mv materialized views (without volume aggregation)
--
-- FOR FRESH DATABASES:
-- Fresh database initialization via Docker entrypoint should use the updated schema files
-- (001-012 with volume columns already included). This migration script is ONLY needed for
-- upgrading existing production databases that were created before volume tracking was added.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: Add Volume Columns to Prices Table
-- ============================================================================
--
-- These ALTER TABLE statements are metadata-only operations in ClickHouse.
-- They do not rewrite existing data on disk. The DEFAULT 0 value is applied
-- only to new inserts and SELECTs (existing rows logically have 0).
--
-- Using separate ALTER statements (not comma-separated) because IF NOT EXISTS
-- on ADD COLUMN works per-statement, making the migration fully idempotent.

ALTER TABLE price_data.prices ADD COLUMN IF NOT EXISTS native_volume_buy Decimal128(0) DEFAULT 0;
ALTER TABLE price_data.prices ADD COLUMN IF NOT EXISTS native_volume_sell Decimal128(0) DEFAULT 0;
ALTER TABLE price_data.prices ADD COLUMN IF NOT EXISTS usdt_volume_buy Decimal128(12) DEFAULT 0;
ALTER TABLE price_data.prices ADD COLUMN IF NOT EXISTS usdt_volume_sell Decimal128(12) DEFAULT 0;

-- ============================================================================
-- SECTION 2: Migrate OHLC Materialized Views to OHLCV
-- ============================================================================
--
-- For each interval (5min, 15min, 1h, 4h, 1d), we use a 3-step migration pattern:
--
--   Step 1: DROP VIEW - Removes the old OHLC view definition
--                       (target table data is completely independent and preserved)
--
--   Step 2: ALTER TABLE - Adds volume_buy_state and volume_sell_state columns to
--                         the target table (metadata-only, instant)
--
--   Step 3: CREATE VIEW - Recreates as OHLCV materialized view with volume aggregation
--                         (matches the updated schema files from Plan 01 exactly)
--
-- This pattern ensures zero data loss. Dropping a materialized view only removes the
-- view definition, not the target table. All historical OHLC data remains intact.
-- Volume aggregation only applies to new price inserts after the migration completes.

-- ----------------------------------------------------------------------------
-- 2.1: Migrate 5-Minute OHLCV
-- ----------------------------------------------------------------------------

-- Step 1: Drop existing materialized view (target table data is preserved)
DROP VIEW IF EXISTS price_data.ohlc_5min_mv;

-- Step 2: Add volume columns to target table (metadata-only, instant)
ALTER TABLE price_data.ohlc_5min ADD COLUMN IF NOT EXISTS volume_buy_state AggregateFunction(sum, Decimal128(12));
ALTER TABLE price_data.ohlc_5min ADD COLUMN IF NOT EXISTS volume_sell_state AggregateFunction(sum, Decimal128(12));

-- Step 3: Recreate as OHLCV materialized view (matching 007_ohlc_5min.sql exactly)
CREATE MATERIALIZED VIEW IF NOT EXISTS price_data.ohlc_5min_mv
TO price_data.ohlc_5min
AS SELECT
    p.asset_id,
    toStartOfFiveMinute(b.block_timestamp) AS interval_start,
    argMinState(p.usdt_price, b.block_timestamp) AS open_state,
    maxState(p.usdt_price) AS high_state,
    minState(p.usdt_price) AS low_state,
    argMaxState(p.usdt_price, b.block_timestamp) AS close_state,
    sumState(p.usdt_volume_buy) AS volume_buy_state,
    sumState(p.usdt_volume_sell) AS volume_sell_state
FROM price_data.prices p
INNER JOIN price_data.blocks b ON p.block_height = b.block_height
GROUP BY p.asset_id, interval_start;

-- ----------------------------------------------------------------------------
-- 2.2: Migrate 15-Minute OHLCV
-- ----------------------------------------------------------------------------

-- Step 1: Drop existing materialized view (target table data is preserved)
DROP VIEW IF EXISTS price_data.ohlc_15min_mv;

-- Step 2: Add volume columns to target table (metadata-only, instant)
ALTER TABLE price_data.ohlc_15min ADD COLUMN IF NOT EXISTS volume_buy_state AggregateFunction(sum, Decimal128(12));
ALTER TABLE price_data.ohlc_15min ADD COLUMN IF NOT EXISTS volume_sell_state AggregateFunction(sum, Decimal128(12));

-- Step 3: Recreate as OHLCV materialized view (matching 008_ohlc_15min.sql exactly)
CREATE MATERIALIZED VIEW IF NOT EXISTS price_data.ohlc_15min_mv
TO price_data.ohlc_15min
AS SELECT
    p.asset_id,
    toStartOfInterval(b.block_timestamp, INTERVAL 15 MINUTE) AS interval_start,
    argMinState(p.usdt_price, b.block_timestamp) AS open_state,
    maxState(p.usdt_price) AS high_state,
    minState(p.usdt_price) AS low_state,
    argMaxState(p.usdt_price, b.block_timestamp) AS close_state,
    sumState(p.usdt_volume_buy) AS volume_buy_state,
    sumState(p.usdt_volume_sell) AS volume_sell_state
FROM price_data.prices p
INNER JOIN price_data.blocks b ON p.block_height = b.block_height
GROUP BY p.asset_id, interval_start;

-- ----------------------------------------------------------------------------
-- 2.3: Migrate 1-Hour OHLCV
-- ----------------------------------------------------------------------------

-- Step 1: Drop existing materialized view (target table data is preserved)
DROP VIEW IF EXISTS price_data.ohlc_1h_mv;

-- Step 2: Add volume columns to target table (metadata-only, instant)
ALTER TABLE price_data.ohlc_1h ADD COLUMN IF NOT EXISTS volume_buy_state AggregateFunction(sum, Decimal128(12));
ALTER TABLE price_data.ohlc_1h ADD COLUMN IF NOT EXISTS volume_sell_state AggregateFunction(sum, Decimal128(12));

-- Step 3: Recreate as OHLCV materialized view (matching 009_ohlc_1h.sql exactly)
CREATE MATERIALIZED VIEW IF NOT EXISTS price_data.ohlc_1h_mv
TO price_data.ohlc_1h
AS SELECT
    p.asset_id,
    toStartOfHour(b.block_timestamp) AS interval_start,
    argMinState(p.usdt_price, b.block_timestamp) AS open_state,
    maxState(p.usdt_price) AS high_state,
    minState(p.usdt_price) AS low_state,
    argMaxState(p.usdt_price, b.block_timestamp) AS close_state,
    sumState(p.usdt_volume_buy) AS volume_buy_state,
    sumState(p.usdt_volume_sell) AS volume_sell_state
FROM price_data.prices p
INNER JOIN price_data.blocks b ON p.block_height = b.block_height
GROUP BY p.asset_id, interval_start;

-- ----------------------------------------------------------------------------
-- 2.4: Migrate 4-Hour OHLCV
-- ----------------------------------------------------------------------------

-- Step 1: Drop existing materialized view (target table data is preserved)
DROP VIEW IF EXISTS price_data.ohlc_4h_mv;

-- Step 2: Add volume columns to target table (metadata-only, instant)
ALTER TABLE price_data.ohlc_4h ADD COLUMN IF NOT EXISTS volume_buy_state AggregateFunction(sum, Decimal128(12));
ALTER TABLE price_data.ohlc_4h ADD COLUMN IF NOT EXISTS volume_sell_state AggregateFunction(sum, Decimal128(12));

-- Step 3: Recreate as OHLCV materialized view (matching 010_ohlc_4h.sql exactly)
CREATE MATERIALIZED VIEW IF NOT EXISTS price_data.ohlc_4h_mv
TO price_data.ohlc_4h
AS SELECT
    p.asset_id,
    toStartOfInterval(b.block_timestamp, INTERVAL 4 HOUR) AS interval_start,
    argMinState(p.usdt_price, b.block_timestamp) AS open_state,
    maxState(p.usdt_price) AS high_state,
    minState(p.usdt_price) AS low_state,
    argMaxState(p.usdt_price, b.block_timestamp) AS close_state,
    sumState(p.usdt_volume_buy) AS volume_buy_state,
    sumState(p.usdt_volume_sell) AS volume_sell_state
FROM price_data.prices p
INNER JOIN price_data.blocks b ON p.block_height = b.block_height
GROUP BY p.asset_id, interval_start;

-- ----------------------------------------------------------------------------
-- 2.5: Migrate 1-Day OHLCV
-- ----------------------------------------------------------------------------

-- Step 1: Drop existing materialized view (target table data is preserved)
DROP VIEW IF EXISTS price_data.ohlc_1d_mv;

-- Step 2: Add volume columns to target table (metadata-only, instant)
ALTER TABLE price_data.ohlc_1d ADD COLUMN IF NOT EXISTS volume_buy_state AggregateFunction(sum, Decimal128(12));
ALTER TABLE price_data.ohlc_1d ADD COLUMN IF NOT EXISTS volume_sell_state AggregateFunction(sum, Decimal128(12));

-- Step 3: Recreate as OHLCV materialized view (matching 011_ohlc_1d.sql exactly)
CREATE MATERIALIZED VIEW IF NOT EXISTS price_data.ohlc_1d_mv
TO price_data.ohlc_1d
AS SELECT
    p.asset_id,
    toStartOfDay(b.block_timestamp) AS interval_start,
    argMinState(p.usdt_price, b.block_timestamp) AS open_state,
    maxState(p.usdt_price) AS high_state,
    minState(p.usdt_price) AS low_state,
    argMaxState(p.usdt_price, b.block_timestamp) AS close_state,
    sumState(p.usdt_volume_buy) AS volume_buy_state,
    sumState(p.usdt_volume_sell) AS volume_sell_state
FROM price_data.prices p
INNER JOIN price_data.blocks b ON p.block_height = b.block_height
GROUP BY p.asset_id, interval_start;

-- ============================================================================
-- SECTION 3: Recreate Query Views with Volume Columns
-- ============================================================================
--
-- CREATE OR REPLACE VIEW is idempotent. These query views expose the volume
-- data from the OHLCV target tables using -Merge combinators to extract final
-- values from -State aggregate functions.

-- ----------------------------------------------------------------------------
-- 3.1: 5-Minute OHLCV Query View
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW price_data.ohlc_5min_query AS
SELECT
    asset_id,
    interval_start,
    argMinMerge(open_state) AS open,
    maxMerge(high_state) AS high,
    minMerge(low_state) AS low,
    argMaxMerge(close_state) AS close,
    sumMerge(volume_buy_state) AS volume_buy,
    sumMerge(volume_sell_state) AS volume_sell,
    sumMerge(volume_buy_state) + sumMerge(volume_sell_state) AS volume_total
FROM price_data.ohlc_5min
WHERE asset_id = {asset_id:UInt32}
  AND interval_start BETWEEN {start_time:DateTime} AND {end_time:DateTime}
GROUP BY asset_id, interval_start
ORDER BY interval_start ASC;

-- ----------------------------------------------------------------------------
-- 3.2: 15-Minute OHLCV Query View
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW price_data.ohlc_15min_query AS
SELECT
    asset_id,
    interval_start,
    argMinMerge(open_state) AS open,
    maxMerge(high_state) AS high,
    minMerge(low_state) AS low,
    argMaxMerge(close_state) AS close,
    sumMerge(volume_buy_state) AS volume_buy,
    sumMerge(volume_sell_state) AS volume_sell,
    sumMerge(volume_buy_state) + sumMerge(volume_sell_state) AS volume_total
FROM price_data.ohlc_15min
WHERE asset_id = {asset_id:UInt32}
  AND interval_start BETWEEN {start_time:DateTime} AND {end_time:DateTime}
GROUP BY asset_id, interval_start
ORDER BY interval_start ASC;

-- ----------------------------------------------------------------------------
-- 3.3: 1-Hour OHLCV Query View
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW price_data.ohlc_1h_query AS
SELECT
    asset_id,
    interval_start,
    argMinMerge(open_state) AS open,
    maxMerge(high_state) AS high,
    minMerge(low_state) AS low,
    argMaxMerge(close_state) AS close,
    sumMerge(volume_buy_state) AS volume_buy,
    sumMerge(volume_sell_state) AS volume_sell,
    sumMerge(volume_buy_state) + sumMerge(volume_sell_state) AS volume_total
FROM price_data.ohlc_1h
WHERE asset_id = {asset_id:UInt32}
  AND interval_start BETWEEN {start_time:DateTime} AND {end_time:DateTime}
GROUP BY asset_id, interval_start
ORDER BY interval_start ASC;

-- ----------------------------------------------------------------------------
-- 3.4: 4-Hour OHLCV Query View
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW price_data.ohlc_4h_query AS
SELECT
    asset_id,
    interval_start,
    argMinMerge(open_state) AS open,
    maxMerge(high_state) AS high,
    minMerge(low_state) AS low,
    argMaxMerge(close_state) AS close,
    sumMerge(volume_buy_state) AS volume_buy,
    sumMerge(volume_sell_state) AS volume_sell,
    sumMerge(volume_buy_state) + sumMerge(volume_sell_state) AS volume_total
FROM price_data.ohlc_4h
WHERE asset_id = {asset_id:UInt32}
  AND interval_start BETWEEN {start_time:DateTime} AND {end_time:DateTime}
GROUP BY asset_id, interval_start
ORDER BY interval_start ASC;

-- ----------------------------------------------------------------------------
-- 3.5: 1-Day OHLCV Query View
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW price_data.ohlc_1d_query AS
SELECT
    asset_id,
    interval_start,
    argMinMerge(open_state) AS open,
    maxMerge(high_state) AS high,
    minMerge(low_state) AS low,
    argMaxMerge(close_state) AS close,
    sumMerge(volume_buy_state) AS volume_buy,
    sumMerge(volume_sell_state) AS volume_sell,
    sumMerge(volume_buy_state) + sumMerge(volume_sell_state) AS volume_total
FROM price_data.ohlc_1d
WHERE asset_id = {asset_id:UInt32}
  AND interval_start BETWEEN {start_time:DateTime} AND {end_time:DateTime}
GROUP BY asset_id, interval_start
ORDER BY interval_start ASC;

-- ============================================================================
-- SECTION 4: Deduplication Strategy Documentation (Phase 12 Implementation Reference)
-- ============================================================================
--
-- This section documents the swap deduplication strategy for Phase 12 volume
-- ingestion implementation. It is included here (rather than in implementation
-- code comments) because the strategy is tightly coupled to the schema design
-- decisions made in Phase 11.
--
-- DEDUPLICATION STRATEGY FOR VOLUME DATA
--
-- 1. ROW-LEVEL DEDUPLICATION:
--    The prices table uses ReplacingMergeTree(block_height) with ORDER BY (asset_id, block_height).
--    Multiple inserts for the same (asset_id, block_height) are deduplicated during background
--    merges. The row with the highest block_height value (the "version" column) is kept.
--
--    For volume data, this means:
--    - If the same block is processed multiple times (e.g., during crash recovery or reorg handling),
--      concurrent price+volume inserts for the same (asset_id, block_height) will be merged.
--    - The LAST inserted volume values will be used (most recent insert wins).
--    - This is consistent with existing price deduplication behavior.
--
-- 2. BATCH-LEVEL DEDUPLICATION:
--    Use insert_deduplication_token with composite key format: 'volume-{minBlock}-{maxBlock}-{rowCount}'
--    This prevents duplicate batch inserts during crash recovery. The pattern is already used by
--    flushPrices() for price data batching and should be extended to cover volume batches.
--
--    Implementation example (Phase 12):
--    ```
--    await clickhouse.insert({
--      table: 'price_data.prices',
--      values: priceRows,
--      clickhouse_settings: {
--        insert_deduplication_token: `volume-${minBlock}-${maxBlock}-${priceRows.length}`
--      }
--    });
--    ```
--
-- 3. BIDIRECTIONAL VOLUME TRACKING:
--    Each swap generates volume for TWO assets:
--    - asset_in gets native_volume_sell (selling this asset) + usdt_volume_sell
--    - asset_out gets native_volume_buy (buying this asset) + usdt_volume_buy
--
--    This is additive with price data. The same (asset_id, block_height) row holds both:
--    - usdt_price (from price calculation logic, existing)
--    - volume fields (from swap event processing, new in Phase 12)
--
--    Example: In a HDX→USDT swap at block 1000:
--    - HDX (asset 0) row: price=0.015, volume_sell=1000 HDX, usdt_volume_sell=15 USDT
--    - USDT (asset 5) row: price=1.0, volume_buy=15 USDT, usdt_volume_buy=15 USDT
--
--    Both assets get ONE row per block. No duplicate rows needed.
--
-- 4. NO-SWAP BLOCKS:
--    Blocks without swaps for a particular asset have DEFAULT 0 for volume columns.
--    No extra rows are inserted for zero-volume blocks.
--
--    This follows the existing sparse storage pattern where only blocks with price changes
--    are stored. A block may have a price update but no volume (price changed due to external
--    swap), or volume but no price change (swap happened at previous block's price).
--
-- 5. SWAP_ID DEDUPLICATION (NOT NEEDED AT STORAGE LAYER):
--    Hydration swap events include swap_id (a unique identifier per swap). However, because
--    we aggregate volumes by (asset_id, block_height) before insertion, swap_id deduplication
--    happens DURING PROCESSING, not at the storage layer.
--
--    Phase 12 implementation will:
--    - Process all swaps in a block
--    - Aggregate volume by asset_id (sum all swaps for each asset in the block)
--    - Insert ONE row per asset per block with total volume
--
--    Swap_id tracking prevents double-counting during processing (e.g., if same swap event
--    appears in multiple runtime versions). Once aggregated to block-level, swap_id is no
--    longer needed.
--
-- 6. REORG HANDLING:
--    Chain reorgs may cause blocks to be reprocessed with different swap events. The
--    ReplacingMergeTree deduplication handles this automatically:
--    - Original block processed: row inserted with volume_A
--    - Reorg detected: same block reprocessed with different swaps
--    - New row inserted with volume_B (same asset_id + block_height)
--    - Background merge keeps the latest row (volume_B)
--
--    This matches existing reorg handling for price data. No special logic needed for volume.
--
-- SUMMARY FOR PHASE 12 IMPLEMENTERS:
-- - Use insert_deduplication_token for batch-level crash recovery safety
-- - Aggregate swaps to (asset_id, block_height) volume sums before insertion
-- - Insert volume alongside price data using the same PriceRow batch
-- - Rely on ReplacingMergeTree for row-level reorg handling
-- - Track swap_id during processing to prevent double-counting, but don't store it
--
-- ============================================================================
-- END OF MIGRATION SCRIPT
-- ============================================================================
