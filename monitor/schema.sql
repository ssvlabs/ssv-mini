-- Enum/duty_type
DO $$ BEGIN
	CREATE TYPE "duty_type" AS ENUM ('sync_committee', 'attest', 'propose');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Table/state
CREATE TABLE IF NOT EXISTS states (
    head_slot int4 NOT NULL,
    sync_slot int4 NOT NULL
);

INSERT INTO states (head_slot, sync_slot) VALUES (0, 0);

CREATE TABLE IF NOT EXISTS committees (
    number SERIAL PRIMARY KEY,
    pool int2 NOT NULL,
    id TEXT NOT NULL,
    operators int4[] NOT NULL,
    last_epoch int4 NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS committees_idx_1
    ON public.committees USING btree (pool, id);

CREATE TABLE IF NOT EXISTS validators (
    pool int2 NOT NULL,
    index int4 PRIMARY KEY,
    committee_number int4 NOT NULL REFERENCES committees (number),
    pubkey bytea NOT NULL,
    status TEXT NOT NULL, -- TODO: index `status` because its being JOINed?
    activation_epoch int4,
    liquidated boolean NOT NULL,
    last_epoch int4 NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS validators_idx_1
    ON public.validators USING btree (index);

-- Table/duties
CREATE TABLE IF NOT EXISTS duties (
    pool int2 NOT NULL,
    committee_number int4 NOT NULL,
    type duty_type,
    epoch int4 NOT NULL GENERATED ALWAYS AS (slot / 32) STORED,
    slot int4 NOT NULL,
    index int4 NOT NULL,
    earliest_incl_offset int2,
    incl_offset int2,
    correct_head_vote boolean NOT NULL,
    success boolean NOT NULL
)  PARTITION BY LIST (pool);

CREATE TABLE duties_pool_1 PARTITION OF duties FOR VALUES IN (1);
CREATE TABLE duties_pool_2 PARTITION OF duties FOR VALUES IN (2);
CREATE TABLE duties_pool_3 PARTITION OF duties FOR VALUES IN (3);
CREATE TABLE duties_pool_4 PARTITION OF duties FOR VALUES IN (4);
CREATE TABLE duties_pool_5 PARTITION OF duties FOR VALUES IN (5);

CREATE UNIQUE INDEX duties_pool_1_unique_idx ON duties_pool_1 (type, slot, index);
CREATE INDEX duties_pool_1_type_epoch_committee_idx ON duties_pool_1 (type, epoch);
CREATE INDEX duties_pool_1_type_epoch_committee_index_idx ON duties_pool_1 (type, committee_number, epoch);

CREATE UNIQUE INDEX duties_pool_2_unique_idx ON duties_pool_2 (type, slot, index);
CREATE INDEX duties_pool_2_type_epoch_committee_idx ON duties_pool_2 (type, epoch, committee_number);

CREATE UNIQUE INDEX duties_pool_3_unique_idx ON duties_pool_3 (type, slot, index);
CREATE INDEX duties_pool_3_type_epoch_committee_idx ON duties_pool_3 (type, epoch, committee_number);

CREATE UNIQUE INDEX duties_pool_4_unique_idx ON duties_pool_4 (type, slot, index);
CREATE INDEX duties_pool_4_type_epoch_committee_idx ON duties_pool_4 (type, epoch, committee_number);

CREATE UNIQUE INDEX duties_pool_5_unique_idx ON duties_pool_5 (type, slot, index);
CREATE INDEX duties_pool_5_type_epoch_committee_idx ON duties_pool_5 (type, epoch, committee_number);

-- Table/committee_stats
CREATE TABLE IF NOT EXISTS committee_stats (
    pool int2 NOT NULL,
    epoch int4 NOT NULL,
    committee_number int4 NOT NULL,
    proposals int2 NOT NULL,
    proposals_executed int2 NOT NULL,
    proposals_missed int2 NOT NULL,
    attestations int2 NOT NULL,
    attestations_executed int2 NOT NULL,
    attestations_missed int2 NOT NULL,
    sync_committee int2 NOT NULL,
    sync_committee_executed int2 NOT NULL,
    sync_committee_missed int2 NOT NULL,
    effectiveness real NOT NULL,
    correct_head_votes int2 NOT NULL,
    PRIMARY KEY (pool, committee_number, epoch)
);

-- Table/epoch_stats
CREATE TABLE IF NOT EXISTS epoch_stats (
    pool int2 NOT NULL,
    epoch int4 NOT NULL,
    proposals int2 NOT NULL,
    proposals_executed int2 NOT NULL,
    proposals_missed int2 NOT NULL,
    attestations int4 NOT NULL,
    attestations_executed int4 NOT NULL,
    attestations_missed int4 NOT NULL,
    sync_committee int2 NOT NULL,
    sync_committee_executed int2 NOT NULL,
    sync_committee_missed int2 NOT NULL,
    effectiveness real NOT NULL,
    correct_head_votes int4 NOT NULL,
    PRIMARY KEY (pool, epoch)
);

-- Table/blocks
CREATE TABLE IF NOT EXISTS blocks (
    slot int8 NOT NULL,
    proposer_index int8 NOT NULL,
    parent_root bytea NOT NULL,
    body_root bytea NOT NULL,
    block_hash bytea NOT NULL UNIQUE,
    slashed_proposers int8[] NOT NULL,
    slashed_attesters int8[] NOT NULL,
    sync_committee_participants int2 NOT NULL,
    attestations_count int2 NOT NULL,
    fee_recipient bytea NOT NULL,
    extra_data bytea,
    PRIMARY KEY (slot)
);

CREATE INDEX IF NOT EXISTS blocks_proposer_index_index
    ON public.blocks (proposer_index);

CREATE INDEX IF NOT EXISTS blocks_fee_recipient_index
    ON public.blocks (fee_recipient);

-- Table/block_bids
CREATE TABLE IF NOT EXISTS block_bids (
    slot int8 NOT NULL,
    block_hash bytea NOT NULL REFERENCES blocks (block_hash),
    relay_name VARCHAR(255) NOT NULL,
    index int8 NOT NULL,
    proposer_fee_recipient bytea,
    value NUMERIC(78),
    PRIMARY KEY (relay_name, block_hash)
);

CREATE INDEX IF NOT EXISTS block_bids_idx_1
    ON public.block_bids USING btree (slot);
CREATE INDEX IF NOT EXISTS block_bids_idx_2
    ON public.block_bids USING btree ((slot / 32));
