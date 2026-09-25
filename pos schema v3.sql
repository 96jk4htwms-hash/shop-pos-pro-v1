-- ============================================================================
-- SMART POS PRO — DATABASE SCHEMA (เขียนใหม่ทั้งหมดโดยอ่านจากพฤติกรรมจริงของ index.html)
-- ----------------------------------------------------------------------------
-- ไฟล์นี้สร้างจากการไล่โค้ด JS ในแอปทุกจุดที่คุยกับ Supabase (.from(), .rpc(),
-- .storage.from()) แล้วดึงชื่อตาราง/คอลัมน์/พารามิเตอร์ที่แอป "คาดหวัง" จริงๆ ออกมา
-- ไม่ใช่เดาจากชื่อ — ปลอดภัยที่จะรันไฟล์นี้ได้ทั้งไฟล์แม้ฐานข้อมูลจะมีตารางบางส่วนอยู่แล้ว
-- จากการรันครั้งก่อน (ทุก CREATE TABLE ตามด้วย ALTER TABLE ... ADD COLUMN IF NOT EXISTS
-- สำหรับคอลัมน์ใหม่ทั้งหมด และทุก CREATE POLICY มี DROP POLICY IF EXISTS นำหน้า) —
-- รันซ้ำกี่ครั้งก็ได้โดยไม่ error
--
-- รันบน Supabase SQL Editor ได้ทั้งไฟล์ตามลำดับนี้เลย (มีลำดับ dependency ถูกต้องแล้ว)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. EXTENSIONS
-- ----------------------------------------------------------------------------
create extension if not exists pgcrypto; -- ให้ gen_random_uuid() ใช้ได้

-- ----------------------------------------------------------------------------
-- 1. CATEGORIES  (หมวดหมู่สินค้า — รองรับหมวดหมู่ย่อยผ่าน parent_id)
-- ----------------------------------------------------------------------------
-- หมายเหตุ: parent_id เป็นคอลัมน์ใหม่ที่ไม่มีในโค้ด sync เดิม (ฝั่งแอปยังไม่ได้ส่งค่า
-- นี้ขึ้นมา) เพิ่มไว้ให้พร้อมสำหรับฟีเจอร์หมวดหมู่ย่อยที่เพิ่งทำในแอป — ถ้าต้องการให้ค่า
-- นี้ sync ขึ้นมาจริง ต้องแก้ syncProductsToSupabase() ในแอปให้ส่ง parent_id เพิ่ม
create table if not exists categories (
  id            uuid primary key,
  name          text not null,
  icon          text default '📁',
  color         text default '#4F46E5',
  display_order integer default 0,
  parent_id     uuid references categories(id) on delete set null,
  created_at    timestamptz not null default now()
);
-- กัน error "column ... does not exist": ถ้าตาราง categories มีอยู่แล้วจากรอบรันก่อนหน้า
-- (เช่นตอนยังไม่มี parent_id) "create table if not exists" ข้างบนจะไม่สร้างคอลัมน์ใหม่ให้
-- เพราะตารางมีอยู่แล้ว ต้องสั่ง ALTER เพิ่มคอลัมน์ทีละคอลัมน์แบบนี้เสมอสำหรับของที่เพิ่มทีหลัง
alter table categories add column if not exists parent_id     uuid references categories(id) on delete set null;
alter table categories add column if not exists icon          text default '📁';
alter table categories add column if not exists color         text default '#4F46E5';
alter table categories add column if not exists display_order integer default 0;
create index if not exists idx_categories_parent on categories(parent_id);

-- ----------------------------------------------------------------------------
-- 2. PRODUCTS  (สินค้าระดับ "กลุ่ม" — ราคา/ทุน/สต็อกอยู่ที่ product_variants ทั้งหมด
--    products เก็บแค่ข้อมูลระดับ catalog ที่ใช้ร่วมกันทุกไซส์/รุ่น)
-- ----------------------------------------------------------------------------
create table if not exists products (
  id               uuid primary key,
  sku              text unique,
  name             text not null,
  image_url        text,
  min_stock_alert  numeric not null default 5,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table products add column if not exists sku              text;
alter table products add column if not exists image_url        text;
alter table products add column if not exists min_stock_alert  numeric not null default 5;
alter table products add column if not exists is_active        boolean not null default true;
alter table products add column if not exists updated_at       timestamptz not null default now();
create index if not exists idx_products_name on products using gin (to_tsvector('simple', name));
create index if not exists idx_products_active on products(is_active);
-- unique index แบบห่อ exception ไว้: ถ้ามีข้อมูลซ้ำอยู่แล้วในฐานข้อมูลจริง (เช่น SKU ซ้ำจาก
-- การใช้งานเดิม) จะแค่เตือนแล้วข้ามไป ไม่ทำให้ทั้งสคริปต์รันไม่ผ่าน — แต่แทนที่จะแค่บอกให้ไปรันเช็ค
-- เองทีหลัง (ซึ่งมักถูกลืม) บล็อกด้านล่างนี้รันการเช็คให้เลยตอนนี้ทันทีและ RAISE NOTICE ออกมาเป็น
-- รายการ SKU ที่ซ้ำจริงพร้อมจำนวนซ้ำ ให้เห็นในหน้าจอ SQL Editor ทันทีว่าต้องไปแก้อะไรบ้าง
do $$
declare
  v_dup record;
  v_found boolean := false;
begin
  for v_dup in
    select sku, count(*) as n from products where sku is not null group by sku having count(*) > 1
  loop
    v_found := true;
    raise notice 'SKU ซ้ำ: "%" พบ % รายการ — ต้องแก้ให้ไม่ซ้ำก่อนจึงจะสร้าง unique index ได้จริง', v_dup.sku, v_dup.n;
  end loop;
  if v_found then
    raise notice 'สรุป: พบ SKU ซ้ำในตาราง products อย่างน้อย 1 ชุด — ระบบยังไม่มี unique constraint บังคับ SKU จนกว่าจะแก้ข้อมูลซ้ำข้างต้นแล้วรันสคริปต์นี้ซ้ำ';
  end if;
end $$;
do $$ begin
  create unique index idx_products_sku_unique on products(sku) where sku is not null;
exception when unique_violation then
  raise notice 'ข้าม unique index บน products.sku — มี SKU ซ้ำอยู่ในข้อมูลจริง (ดูรายการ SKU ที่ซ้ำใน NOTICE ด้านบน) ต้องแก้ให้ไม่ซ้ำก่อน แล้วรันสคริปต์นี้ใหม่';
when duplicate_table then null;
end $$;

-- ----------------------------------------------------------------------------
-- 3. PRODUCT_CATEGORIES  (จุดเชื่อม many-to-many — 1 สินค้าอยู่ได้หลายหมวดหมู่)
-- ----------------------------------------------------------------------------
create table if not exists product_categories (
  product_id  uuid not null references products(id) on delete cascade,
  category_id uuid not null references categories(id) on delete cascade,
  primary key (product_id, category_id)
);
create index if not exists idx_prodcat_category on product_categories(category_id);

-- ----------------------------------------------------------------------------
-- 4. PRODUCT_VARIANTS  (แต่ละไซส์/สี/รุ่นของสินค้า — ราคา/ทุน/สต็อกอยู่ตรงนี้)
-- ----------------------------------------------------------------------------
create table if not exists product_variants (
  id              uuid primary key,
  product_id      uuid not null references products(id) on delete cascade,
  variant_name    text not null default 'ปกติ',
  barcode         text,
  price           numeric not null default 0 check (price >= 0),
  cost_price      numeric not null default 0 check (cost_price >= 0),
  stock_quantity  numeric not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);
alter table product_variants add column if not exists barcode        text;
alter table product_variants add column if not exists cost_price     numeric not null default 0;
alter table product_variants add column if not exists is_active      boolean not null default true;
-- ห่อ exception เหมือนกัน: บาร์โค้ดซ้ำ (เช่น "SKU1570") มักเกิดจากสินค้าหลายชิ้นที่ยังไม่ได้
-- ตั้งบาร์โค้ดจริง แล้วแอปเคยเติมค่า placeholder ซ้ำๆ กันไว้ — ถ้าซ้ำอยู่จริงจะข้ามการบังคับ
-- unique ไปก่อน (ไม่บล็อกการรันสคริปต์) แต่แทนที่จะบอกให้ไปรันเช็คเองทีหลัง บล็อกด้านล่างนี้
-- รันการเช็คให้ทันทีและ RAISE NOTICE รายการบาร์โค้ดที่ซ้ำจริงพร้อมจำนวนซ้ำออกมาให้เห็นเลย
-- (บาร์โค้ดซ้ำมีผลจริงกับหน้าขาย เพราะระบบสแกนอ้างอิงจากบาร์โค้ดเป็นตัวค้นหาสินค้า)
do $$
declare
  v_dup record;
  v_found boolean := false;
begin
  for v_dup in
    select barcode, count(*) as n from product_variants where barcode is not null group by barcode having count(*) > 1
  loop
    v_found := true;
    raise notice 'บาร์โค้ดซ้ำ: "%" พบ % รายการ — สแกนบาร์โค้ดนี้จะได้สินค้าไม่แน่นอนว่าตัวไหน ต้องแก้ก่อน', v_dup.barcode, v_dup.n;
  end loop;
  if v_found then
    raise notice 'สรุป: พบบาร์โค้ดซ้ำในตาราง product_variants อย่างน้อย 1 ชุด — ระบบยังไม่มี unique constraint บังคับบาร์โค้ดจนกว่าจะแก้ข้อมูลซ้ำข้างต้นแล้วรันสคริปต์นี้ซ้ำ';
  end if;
end $$;
do $$ begin
  create unique index idx_variants_barcode on product_variants(barcode) where barcode is not null;
exception when unique_violation then
  raise notice 'ข้าม unique index บน product_variants.barcode — มีบาร์โค้ดซ้ำอยู่ในข้อมูลจริง (ดูรายการที่ซ้ำใน NOTICE ด้านบน) ต้องแก้ให้ไม่ซ้ำก่อน แล้วรันสคริปต์นี้ใหม่';
when duplicate_table then null;
end $$;
create index if not exists idx_variants_product on product_variants(product_id);

-- ----------------------------------------------------------------------------
-- 5. PRODUCT_FRACTIONS  (หน่วยแบ่งขาย เช่น ตัดสายไฟขายเป็นเมตรจากม้วน 100 ม.)
-- ----------------------------------------------------------------------------
-- quantity_ratio = "1 หน่วยที่นับเป็นสต็อกจริง เท่ากับกี่หน่วยแบ่งขายนี้"
-- เช่น ม้วนสายไฟ 100 เมตร ขายปลีกเป็นเมตร -> quantity_ratio = 100
-- ตอนขาย ให้หักสต็อก = quantity_sold / quantity_ratio (ดู create_sale ด้านล่าง)
create table if not exists product_fractions (
  id              uuid primary key,
  variant_id      uuid not null references product_variants(id) on delete cascade,
  fraction_name   text not null,
  quantity_ratio  numeric not null check (quantity_ratio > 0),
  price           numeric not null default 0 check (price >= 0),
  barcode         text
);
alter table product_fractions add column if not exists barcode text;
create index if not exists idx_fractions_variant on product_fractions(variant_id);

-- ----------------------------------------------------------------------------
-- 6. CUSTOMERS  (ไม่มีคอลัมน์ยอดหนี้ค้าง — แอปเก็บยอดหนี้/debt ไว้ในเครื่องเท่านั้น
--    เพราะยังไม่มีที่ทางฝั่ง server ให้เก็บตอนนี้ — ดูหมายเหตุท้ายไฟล์)
-- ----------------------------------------------------------------------------
create table if not exists customers (
  id            uuid primary key,
  name          text not null,
  phone         text,
  address       text default '',
  credit_limit  numeric not null default 0,
  debt          numeric not null default 0,
  created_at    timestamptz not null default now()
);
alter table customers add column if not exists phone        text;
alter table customers add column if not exists address      text default '';
alter table customers add column if not exists credit_limit numeric not null default 0;
-- debt = ยอดหนี้ค้างชำระ (เดิมเก็บในเครื่องอย่างเดียว) — เพิ่มขึ้นมาให้ create_sale/process_return
-- บังคับวงเงินเครดิตได้จริงฝั่งเซิร์ฟเวอร์ แทนที่จะพึ่งการเช็คฝั่ง client เพียงอย่างเดียว
-- (ค่าตั้งต้น sync มาจาก db.customers[].debt ที่แอปคำนวณสะสมไว้อยู่แล้ว ดู syncProductsToSupabase)
alter table customers add column if not exists debt          numeric not null default 0;

-- ----------------------------------------------------------------------------
-- 7. SUPPLIERS
-- ----------------------------------------------------------------------------
create table if not exists suppliers (
  id          uuid primary key,
  name        text not null,
  phone       text,
  address     text default '',
  created_at  timestamptz not null default now()
);
alter table suppliers add column if not exists phone   text;
alter table suppliers add column if not exists address text default '';

-- ----------------------------------------------------------------------------
-- 8. APP_USERS  (พนักงาน/เจ้าของร้าน — แทนที่ profiles/employees เดิม)
-- ----------------------------------------------------------------------------
-- auth_user_id ผูกกับ auth.users จริงสำหรับพนักงาน/เจ้าของร้านที่ผ่านการ "provision" แล้ว —
-- ตั้งแต่มี window.provisionEmployeeAuthAccount ฝั่งแอป ทุก role (ไม่ใช่แค่ OWNER อีกต่อไป) จะได้
-- บัญชี Supabase Auth สังเคราะห์เป็นของตัวเอง (อีเมลปลอมแบบ emp-<id>@pos.local + รหัสผ่านสุ่มที่
-- อุปกรณ์จำไว้ในเครื่อง ไม่เคยส่งขึ้น Supabase) เพื่อให้ is_manager()/is_staff() เช็คตรงกับ
-- "พนักงานที่ล็อกอิน PIN อยู่จริงตอนนี้" แทนที่จะเช็คแค่ session อุปกรณ์ที่ล็อกอินไว้เฉยๆ — ยังคง
-- เป็น NULL ได้สำหรับพนักงานที่ยังไม่เคย provision บนอุปกรณ์ไหนเลย (เช่นเพิ่งสร้างขณะออฟไลน์)
create table if not exists app_users (
  id            uuid primary key,
  auth_user_id  uuid references auth.users(id) on delete set null,
  name          text not null,
  pin           text not null, -- เก็บเฉพาะ SHA-256 hash เท่านั้น ห้ามเก็บเลข PIN ดิบเด็ดขาด
  role          text not null default 'CASHIER' check (role in ('OWNER','MANAGER','CASHIER')),
  permissions   jsonb not null default '[]'::jsonb,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
alter table app_users add column if not exists auth_user_id uuid references auth.users(id) on delete set null;
alter table app_users add column if not exists permissions  jsonb not null default '[]'::jsonb;
alter table app_users add column if not exists is_active    boolean not null default true;
do $$ begin
  create unique index idx_app_users_auth on app_users(auth_user_id) where auth_user_id is not null;
exception when unique_violation then
  raise notice 'ข้าม unique index บน app_users.auth_user_id — มีพนักงานมากกว่า 1 คนผูกกับบัญชี Supabase Auth เดียวกันอยู่ ควรตรวจสอบ';
when duplicate_table then null;
end $$;
do $$ begin
  create unique index idx_app_users_one_owner on app_users((role = 'OWNER')) where role = 'OWNER';
exception when unique_violation then
  raise notice 'ข้าม unique index กัน OWNER ซ้ำ — มี OWNER มากกว่า 1 คนอยู่แล้วในข้อมูลจริง ควรตรวจสอบว่าตั้งใจหรือไม่';
when duplicate_table then null;
end $$;

-- ----------------------------------------------------------------------------
-- 9. SHIFTS  (เปิด-ปิดร้าน / เงินทอนเริ่มต้น-ปิด)
-- ----------------------------------------------------------------------------
create table if not exists shifts (
  id            uuid primary key,
  opened_at     timestamptz not null,
  closed_at     timestamptz,
  opening_cash  numeric not null default 0,
  closing_cash  numeric,
  status        text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
  opened_by     uuid references app_users(id),
  closed_by     uuid references app_users(id)
);
alter table shifts add column if not exists opening_cash numeric not null default 0;
alter table shifts add column if not exists closing_cash numeric;
alter table shifts add column if not exists opened_by    uuid references app_users(id);
alter table shifts add column if not exists closed_by    uuid references app_users(id);
create index if not exists idx_shifts_status on shifts(status);

-- ----------------------------------------------------------------------------
-- 10. BILLS  (บิลขาย)
-- ----------------------------------------------------------------------------
create table if not exists bills (
  id                uuid primary key,
  bill_number       text not null unique,
  customer_id       uuid references customers(id),
  user_id           uuid references app_users(id),
  shift_id          uuid references shifts(id),
  subtotal          numeric not null default 0,
  discount_amount   numeric not null default 0,
  tax_amount        numeric not null default 0,
  total             numeric not null default 0,
  payment_method    text not null default 'CASH', -- CASH / TRANSFER / CREDIT (ไม่ได้บังคับด้วย CHECK ตามที่แอปคาดหวัง)
  status            text not null default 'PAID' check (status in ('PAID','CANCELLED')),
  created_at        timestamptz not null default now()
);
alter table bills add column if not exists shift_id        uuid references shifts(id);
alter table bills add column if not exists discount_amount numeric not null default 0;
alter table bills add column if not exists tax_amount      numeric not null default 0;
alter table bills add column if not exists status          text not null default 'PAID';
create index if not exists idx_bills_shift on bills(shift_id);
create index if not exists idx_bills_customer on bills(customer_id);
create index if not exists idx_bills_created on bills(created_at);

-- ----------------------------------------------------------------------------
-- 11. BILL_ITEMS
-- ----------------------------------------------------------------------------
create table if not exists bill_items (
  id            uuid primary key,
  bill_id       uuid not null references bills(id) on delete cascade,
  product_id    uuid references products(id),
  variant_id    uuid references product_variants(id),
  fraction_id   uuid references product_fractions(id),
  item_name     text not null,
  quantity      numeric not null,
  unit_price    numeric not null,
  line_total    numeric not null
);
alter table bill_items add column if not exists fraction_id uuid references product_fractions(id);
create index if not exists idx_bill_items_bill on bill_items(bill_id);

-- ----------------------------------------------------------------------------
-- 12. PURCHASE_ORDERS / PURCHASE_ORDER_ITEMS  (รับสินค้าเข้าคลังจากซัพพลายเออร์)
-- ----------------------------------------------------------------------------
create table if not exists purchase_orders (
  id             uuid primary key default gen_random_uuid(),
  po_number      text,
  supplier_id    uuid references suppliers(id),
  status         text not null default 'ORDERED' check (status in ('ORDERED','RECEIVED','CANCELLED')),
  document_ref   text,
  credit_terms   integer default 30,
  ordered_at     timestamptz not null default now(),
  received_at    timestamptz
);
alter table purchase_orders add column if not exists document_ref text;
alter table purchase_orders add column if not exists credit_terms integer default 30;
alter table purchase_orders add column if not exists received_at  timestamptz;

create table if not exists purchase_order_items (
  id                    uuid primary key default gen_random_uuid(),
  purchase_order_id     uuid not null references purchase_orders(id) on delete cascade,
  product_id            uuid references products(id),
  variant_id            uuid references product_variants(id),
  quantity              numeric not null,
  unit_cost             numeric not null default 0,
  received_quantity     numeric not null default 0
);
alter table purchase_order_items add column if not exists received_quantity numeric not null default 0;

-- ----------------------------------------------------------------------------
-- 13. INVENTORY_MOVEMENTS  (ออดิทสต็อก — เขียนโดย receive_purchase_order() เท่านั้น)
-- ----------------------------------------------------------------------------
create table if not exists inventory_movements (
  id           uuid primary key default gen_random_uuid(),
  variant_id   uuid not null references product_variants(id),
  change_qty   numeric not null,     -- + เข้าสต็อก, - ออกสต็อก
  reason       text not null,        -- 'PURCHASE_RECEIPT', 'SALE', 'ADJUSTMENT', ...
  ref_type     text,                 -- 'purchase_order' / 'bill' / ...
  ref_id       uuid,
  created_at   timestamptz not null default now()
);
alter table inventory_movements add column if not exists ref_type text;
alter table inventory_movements add column if not exists ref_id   uuid;
create index if not exists idx_inv_move_variant on inventory_movements(variant_id);

-- ----------------------------------------------------------------------------
-- 14. CASH_LEDGER  (เงินสดเข้า/ออกลิ้นชักจริง — รับชำระหนี้, คืนเงิน, เงินเข้า/ออกที่บันทึกมือ)
-- ----------------------------------------------------------------------------
-- syncTransactionsToSupabase() ในแอปจะ push เข้าตารางนี้ทั้ง (1) db.cashLedger entries
-- ชนิด 'cash-in-ar' / 'expense-refund' และ (2) รายการเงินเข้า/ออกที่บันทึกมือระหว่างกะ
-- (db.shifts[].movements ชนิด 'IN'/'OUT' แปลงเป็น 'SHIFT_CASH_IN'/'SHIFT_CASH_OUT' ที่นี่)
-- ส่วน 'ACCOUNTS_PAYABLE' ไม่ได้อยู่ในตารางนี้แล้ว — ย้ายไปตาราง accounts_payable (14b)
-- ด้านล่างแทน เพราะเป็นยอดหนี้ค้างจ่าย ไม่ใช่รายการเงินสดเข้า/ออกแบบ income/expense
create table if not exists cash_ledger (
  id           uuid primary key default gen_random_uuid(),
  shift_id     uuid references shifts(id),
  type         text not null,  -- 'cash-in-ar' / 'expense-refund' / 'SHIFT_CASH_IN' / 'SHIFT_CASH_OUT'
  income       numeric not null default 0,
  expense      numeric not null default 0,
  description  text,
  ref_id       text,
  created_at   timestamptz not null default now()
);
create index if not exists idx_cash_ledger_shift on cash_ledger(shift_id);

-- ----------------------------------------------------------------------------
-- 14b. ACCOUNTS_PAYABLE  (เจ้าหนี้การค้า จากการรับสินค้าเข้าคลัง)
-- ----------------------------------------------------------------------------
-- แยกออกมาจาก cash_ledger โดยเจตนา: รายการนี้คือ "ยอดหนี้ค้างจ่าย" (a balance owed),
-- ไม่ใช่รายการเงินสดเข้า/ออกจริงแบบ income/expense — โครงสร้างต่างกัน (amount/supplier_id/
-- terms/status แทน income/expense/description) เหมือน customers.debt แต่ฝั่งซัพพลายเออร์
-- แทน ตรงกับ db.cashLedger entries ชนิด 'ACCOUNTS_PAYABLE' ที่แอปสร้างตอนรับสินค้าเข้าคลัง
-- (window.confirmReceivePO) — ไม่ยัดรวมเป็นแถวใน cash_ledger เพราะจะไม่มีคอลัมน์ไหนรับ
-- amount/terms/status ได้ตรงความหมายเลย
create table if not exists accounts_payable (
  id                 uuid primary key,
  supplier_id        uuid references suppliers(id),
  purchase_order_id  uuid references purchase_orders(id) on delete set null,
  doc_ref            text,
  amount             numeric not null default 0 check (amount >= 0),
  credit_terms       integer default 30,
  status             text not null default 'OPEN' check (status in ('OPEN','PAID')),
  created_at         timestamptz not null default now(),
  paid_at            timestamptz
);
alter table accounts_payable add column if not exists paid_at timestamptz;
create index if not exists idx_ap_supplier on accounts_payable(supplier_id);
create index if not exists idx_ap_status   on accounts_payable(status);

-- ============================================================================
-- 15. HELPER FUNCTIONS สำหรับ RLS (ใช้ auth.uid() เทียบกับ app_users.auth_user_id)
-- ============================================================================
-- DROP FUNCTION นำหน้าฟังก์ชัน RPC หลักทั้ง 3 ตัวเสมอ: CREATE OR REPLACE ใช้ไม่ได้ถ้า
-- ฟังก์ชันเดิมมี return type ต่างจากที่เขียนใหม่ (เช่นเคยมีเวอร์ชันทดลองที่ return ไม่เหมือนกัน)
-- (ไม่ทำแบบเดียวกันกับ is_staff/is_manager/is_owner ด้านล่าง เพราะ RLS policy อ้างอิงฟังก์ชัน
-- พวกนั้นอยู่ — ถ้า DROP จะพังตอนรันซ้ำครั้งที่สองเพราะมี object อื่นอ้างอิงอยู่ ส่วน RPC 3 ตัวนี้
-- ไม่มีอะไรอ้างอิงอยู่ จึง DROP ได้อย่างปลอดภัย)
-- DROP FUNCTION แบบระบุ signature ตรงๆ อาจไม่ตรงกับของเดิมในฐานข้อมูลจริง 100% (เช่นพารามิเตอร์
-- เดิมเป็นคนละชนิด/มี default อยู่) ทำให้ DROP...IF EXISTS หาไม่เจอ แล้ว CREATE OR REPLACE ชนกับ
-- ของเดิมที่ยังไม่ถูกลบอีกครั้ง — เปลี่ยนมาค้นหาทุก overload ของชื่อฟังก์ชันนี้จาก pg_proc ตรงๆ
-- แล้ว DROP ... CASCADE ทิ้งให้หมดไม่ว่าจะมี signature หน้าตาแบบไหนอยู่ก่อนก็ตาม
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.proname in ('bootstrap_first_owner', 'create_sale', 'receive_purchase_order', 'process_return', 'receive_customer_payment')
      and pg_function_is_visible(p.oid)
  loop
    execute format('drop function if exists %s cascade;', r.sig);
  end loop;
end $$;

create or replace function is_staff() returns boolean
language sql security definer stable as $$
  select exists (select 1 from app_users where auth_user_id = auth.uid() and is_active);
$$;

create or replace function is_manager() returns boolean
language sql security definer stable as $$
  select exists (
    select 1 from app_users
    where auth_user_id = auth.uid() and is_active and role in ('OWNER','MANAGER')
  );
$$;

create or replace function is_owner() returns boolean
language sql security definer stable as $$
  select exists (
    select 1 from app_users where auth_user_id = auth.uid() and is_active and role = 'OWNER'
  );
$$;

-- ============================================================================
-- 16. ROW LEVEL SECURITY
-- ============================================================================
alter table categories           enable row level security;
alter table products             enable row level security;
alter table product_categories   enable row level security;
alter table product_variants     enable row level security;
alter table product_fractions    enable row level security;
alter table customers            enable row level security;
alter table suppliers            enable row level security;
alter table app_users            enable row level security;
alter table shifts               enable row level security;
alter table bills                enable row level security;
alter table bill_items           enable row level security;
alter table purchase_orders      enable row level security;
alter table purchase_order_items enable row level security;
alter table inventory_movements  enable row level security;
alter table cash_ledger          enable row level security;
alter table accounts_payable     enable row level security;

-- พนักงานที่ล็อกอินแล้ว (มีแถวใน app_users) อ่าน/แก้ไขข้อมูลการขายประจำวันได้ทั้งหมด —
-- แคชเชียร์ต้องเปิดร้าน/ขายของ/เพิ่มลูกค้าได้โดยไม่ต้องรอสิทธิ์ manager
-- (drop policy if exists ก่อนสร้างทุกครั้ง เพื่อให้รันสคริปต์นี้ซ้ำได้โดยไม่ error
-- "policy already exists" ถ้าเคยรันผ่านไปแล้วบางส่วนก่อนหน้านี้)
do $$
declare t text;
begin
  foreach t in array array['categories','products','product_categories','product_variants',
                            'product_fractions','customers','shifts','bills','bill_items',
                            'purchase_orders','purchase_order_items','inventory_movements','cash_ledger',
                            'accounts_payable']
  loop
    execute format('drop policy if exists "staff_select_%1$s" on %1$s;', t);
    execute format('drop policy if exists "staff_insert_%1$s" on %1$s;', t);
    execute format('drop policy if exists "staff_update_%1$s" on %1$s;', t);
    execute format('drop policy if exists "manager_delete_%1$s" on %1$s;', t);
    execute format('create policy "staff_select_%1$s" on %1$s for select using (is_staff());', t);
    execute format('create policy "staff_insert_%1$s" on %1$s for insert with check (is_staff());', t);
    execute format('create policy "staff_update_%1$s" on %1$s for update using (is_staff()) with check (is_staff());', t);
    -- ลบข้อมูลจำกัดไว้ที่ manager ขึ้นไปเท่านั้น (กันแคชเชียร์ลบประวัติขาย/สินค้าโดยไม่ตั้งใจ)
    execute format('create policy "manager_delete_%1$s" on %1$s for delete using (is_manager());', t);
  end loop;
end $$;

-- suppliers: เหมือนกลุ่มบนแต่แยกไว้เผื่ออยากจำกัดสิทธิ์ต่างจากกลุ่มขายในอนาคต
drop policy if exists "staff_select_suppliers" on suppliers;
drop policy if exists "manager_write_suppliers" on suppliers;
create policy "staff_select_suppliers" on suppliers for select using (is_staff());
create policy "manager_write_suppliers" on suppliers for all using (is_manager()) with check (is_manager());

-- app_users: พนักงานเห็นได้แค่แถวตัวเอง, manager ขึ้นไปเห็น/แก้ไขได้ทุกคน
drop policy if exists "self_select_app_users" on app_users;
drop policy if exists "manager_write_app_users" on app_users;
drop policy if exists "manager_update_app_users" on app_users;
drop policy if exists "manager_delete_app_users" on app_users;
create policy "self_select_app_users" on app_users for select
  using (auth_user_id = auth.uid() or is_manager());
create policy "manager_write_app_users" on app_users for insert with check (is_manager());
create policy "manager_update_app_users" on app_users for update
  using (is_manager()) with check (is_manager());
create policy "manager_delete_app_users" on app_users for delete using (is_manager());

-- ============================================================================
-- 17. RPC: bootstrap_first_owner(p_name, p_pin)
-- ----------------------------------------------------------------------------
-- เรียกครั้งแรกหลัง sign-in ด้วยอีเมล/รหัสผ่านของ Supabase Auth เพื่อสร้างบัญชี OWNER
-- คนแรกของร้าน — ปฏิเสธเงียบๆ ถ้ามี OWNER อยู่แล้ว (ตรงกับที่แอปเช็คข้อความ error
-- "มี OWNER อยู่แล้ว" เพื่อโชว์ alert ที่เหมาะสม)
-- ============================================================================
create or replace function bootstrap_first_owner(p_name text, p_pin text)
returns uuid
language plpgsql security definer as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'ต้องเข้าสู่ระบบก่อนตั้งค่าเจ้าของร้าน';
  end if;
  if exists (select 1 from app_users where role = 'OWNER') then
    raise exception 'มี OWNER อยู่แล้ว';
  end if;

  insert into app_users (id, auth_user_id, name, pin, role, permissions, is_active)
  values (gen_random_uuid(), auth.uid(), p_name, p_pin, 'OWNER', '["ALL"]'::jsonb, true)
  returning id into new_id;

  return new_id;
end;
$$;

-- ============================================================================
-- 18. RPC: create_sale(...)  — จุดขายจริงแบบอะตอมมิก (atomic) เดียวที่แอปเรียกใช้
-- ----------------------------------------------------------------------------
-- คำนวณ subtotal/total เองจาก p_items (ไม่รับ total จากฝั่ง client) หักสต็อกให้ตรง
-- ทันทีในธุรกรรมเดียว: ถ้าเป็นแบ่งขาย (fraction_id ไม่ว่าง) หักสต็อก = quantity / quantity_ratio
-- ของ fraction นั้น ไม่งั้นหักสต็อก = quantity ตรงๆ จากตัว variant
-- ============================================================================
create or replace function create_sale(
  p_bill_number     text,
  p_customer_id     uuid,
  p_user_id         uuid,
  p_shift_id        uuid,
  p_discount_amount numeric,
  p_tax_amount      numeric,
  p_payment_method  text,
  p_items           jsonb
) returns jsonb
language plpgsql security definer as $$
declare
  v_bill_id   uuid := gen_random_uuid();
  v_subtotal  numeric := 0;
  v_total     numeric;
  v_item      jsonb;
  v_variant   product_variants%rowtype;
  v_ratio     numeric;
  v_deduct    numeric;
  v_customer  customers%rowtype;
begin
  if not is_staff() then
    raise exception 'ไม่มีสิทธิ์บันทึกการขาย';
  end if;

  -- รอบแรก: คำนวณยอดรวมจากราคาที่ client ส่งมา (สินค้าที่มีอยู่จริงเท่านั้น)
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_subtotal := v_subtotal + ((v_item->>'quantity')::numeric * (v_item->>'unit_price')::numeric);
  end loop;
  v_total := v_subtotal - coalesce(p_discount_amount, 0) + coalesce(p_tax_amount, 0);

  -- บังคับวงเงินเครดิตจริงฝั่งเซิร์ฟเวอร์ (เดิมเช็คแค่ฝั่ง client เท่านั้น แก้ client ตรงๆ หรือขาย
  -- พร้อมกันจากหลายเครื่องก็ข้ามได้) — ล็อกแถวลูกค้ากันแข่งกันขายเครดิตพร้อมกันจนเกินวงเงิน
  if upper(coalesce(p_payment_method,'CASH')) = 'CREDIT' and p_customer_id is not null then
    select * into v_customer from customers where id = p_customer_id for update;
    if found and (v_customer.debt + v_total) > v_customer.credit_limit then
      raise exception 'ยอดหนี้รวมจะเกินวงเงินเครดิตที่กำหนดไว้ (วงเงิน % หนี้เดิม % ยอดนี้ %)',
        v_customer.credit_limit, v_customer.debt, v_total;
    end if;
    if found then
      update customers set debt = debt + v_total where id = p_customer_id;
    end if;
  end if;

  insert into bills (id, bill_number, customer_id, user_id, shift_id, subtotal,
                      discount_amount, tax_amount, total, payment_method, status)
  values (v_bill_id, p_bill_number, p_customer_id, p_user_id, p_shift_id, v_subtotal,
          coalesce(p_discount_amount,0), coalesce(p_tax_amount,0), v_total,
          coalesce(p_payment_method,'CASH'), 'PAID');

  -- รอบสอง: บันทึกรายการ + หักสต็อกจริงทีละบรรทัด (ล็อกแถว variant กันแข่งกันขายพร้อมกัน)
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into bill_items (id, bill_id, product_id, variant_id, fraction_id,
                             item_name, quantity, unit_price, line_total)
    values (
      gen_random_uuid(), v_bill_id,
      nullif(v_item->>'product_id','')::uuid,
      nullif(v_item->>'variant_id','')::uuid,
      nullif(v_item->>'fraction_id','')::uuid,
      v_item->>'item_name',
      (v_item->>'quantity')::numeric,
      (v_item->>'unit_price')::numeric,
      (v_item->>'quantity')::numeric * (v_item->>'unit_price')::numeric
    );

    if nullif(v_item->>'variant_id','') is not null then
      select * into v_variant from product_variants
        where id = (v_item->>'variant_id')::uuid for update;

      if nullif(v_item->>'fraction_id','') is not null then
        select quantity_ratio into v_ratio from product_fractions
          where id = (v_item->>'fraction_id')::uuid;
        v_deduct := (v_item->>'quantity')::numeric / coalesce(v_ratio, 1);
      else
        v_deduct := (v_item->>'quantity')::numeric;
      end if;

      if found and v_variant.stock_quantity - v_deduct < 0 then
        raise exception 'สินค้า "%" คงเหลือไม่พอ (คงเหลือ % ต้องการหัก %)',
          v_item->>'item_name', v_variant.stock_quantity, v_deduct;
      end if;

      update product_variants set stock_quantity = stock_quantity - v_deduct
        where id = v_variant.id;

      insert into inventory_movements (variant_id, change_qty, reason, ref_type, ref_id)
      values (v_variant.id, -v_deduct, 'SALE', 'bill', v_bill_id);
    end if;
  end loop;

  return jsonb_build_object('bill_id', v_bill_id);
end;
$$;

-- ============================================================================
-- 19. RPC: receive_purchase_order(p_purchase_order_id, p_items)
-- ----------------------------------------------------------------------------
-- ต้องเป็น manager ขึ้นไป (ตรงกับคอมเมนต์ในแอป) — ล็อกแถว item กันรับซ้ำ, ตรวจว่า
-- จำนวนที่รับไม่เกินจำนวนที่สั่ง, บวกสต็อกเข้า variant จริง และเขียนออดิท
-- p_items รูปแบบ: [{ purchase_order_item_id, received_quantity }, ...]
-- ============================================================================
create or replace function receive_purchase_order(
  p_purchase_order_id uuid,
  p_items             jsonb
) returns void
language plpgsql security definer as $$
declare
  v_item    jsonb;
  v_poi     purchase_order_items%rowtype;
  v_new_recv numeric;
begin
  if not is_manager() then
    raise exception 'ต้องเป็นผู้จัดการขึ้นไปจึงจะรับสินค้าเข้าคลังได้';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    select * into v_poi from purchase_order_items
      where id = (v_item->>'purchase_order_item_id')::uuid for update;

    if not found then
      raise exception 'ไม่พบรายการสั่งซื้อ id=%', v_item->>'purchase_order_item_id';
    end if;

    v_new_recv := v_poi.received_quantity + (v_item->>'received_quantity')::numeric;
    if v_new_recv > v_poi.quantity then
      raise exception 'รับสินค้าเกินจำนวนที่สั่ง (สั่ง % แต่รับรวมแล้ว %)', v_poi.quantity, v_new_recv;
    end if;

    update purchase_order_items set received_quantity = v_new_recv where id = v_poi.id;

    if v_poi.variant_id is not null then
      update product_variants
        set stock_quantity = stock_quantity + (v_item->>'received_quantity')::numeric
        where id = v_poi.variant_id;

      insert into inventory_movements (variant_id, change_qty, reason, ref_type, ref_id)
      values (v_poi.variant_id, (v_item->>'received_quantity')::numeric,
              'PURCHASE_RECEIPT', 'purchase_order', p_purchase_order_id);
    end if;
  end loop;

  update purchase_orders set status = 'RECEIVED', received_at = now()
    where id = p_purchase_order_id
      and not exists (
        select 1 from purchase_order_items
        where purchase_order_id = p_purchase_order_id
          and received_quantity < quantity
      );
end;
$$;

-- ============================================================================
-- 19b. RPC: process_return(p_bill_id, p_items, p_full_return)
-- ----------------------------------------------------------------------------
-- แก้บัค: เดิมการคืนสินค้า/รับคืนบิล (window.executeReturn ในแอป) เป็น local-only ล้วนๆ —
-- ไม่มี RPC ฝั่งนี้เลย ทำให้บิลที่ sync ขึ้นมาแล้วผ่าน create_sale ไม่มีทางอัปเดตสถานะเป็น
-- CANCELLED และสต็อกที่คืนเข้าคลังก็ไม่เคยถูกบวกกลับบน Supabase — รายงานฝั่งเซิร์ฟเวอร์เพี้ยน
-- สะสมทุกครั้งที่มีการคืนสินค้า RPC นี้ทำให้ atomic เหมือน create_sale: คืนสต็อกจริง (หาร
-- quantity_ratio เหมือนตอนขายถ้าเป็นแบ่งขาย), เขียนออดิทลง inventory_movements, อัปเดตสถานะบิล,
-- และลดยอดหนี้ลูกค้าถ้าเป็นบิลเครดิต
-- p_items ใช้ shape เดียวกับ p_items ของ create_sale (variant_id/fraction_id/quantity/unit_price)
-- แทนที่จะอ้าง bill_items.id เพราะ create_sale ไม่เคยส่ง id แถวนั้นกลับมาให้ client รู้จักเลย
-- ============================================================================
create or replace function process_return(
  p_bill_id     uuid,
  p_items       jsonb,
  p_full_return boolean
) returns jsonb
language plpgsql security definer as $$
declare
  v_item        jsonb;
  v_variant     product_variants%rowtype;
  v_ratio       numeric;
  v_restock     numeric;
  v_bill        bills%rowtype;
  v_refund_total numeric := 0;
begin
  if not is_staff() then
    raise exception 'ไม่มีสิทธิ์บันทึกการคืนสินค้า';
  end if;

  select * into v_bill from bills where id = p_bill_id for update;
  if not found then
    raise exception 'ไม่พบบิล id=%', p_bill_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_refund_total := v_refund_total
      + (v_item->>'quantity')::numeric * (v_item->>'unit_price')::numeric;

    if nullif(v_item->>'variant_id','') is not null then
      select * into v_variant from product_variants
        where id = (v_item->>'variant_id')::uuid for update;

      if found then
        if nullif(v_item->>'fraction_id','') is not null then
          select quantity_ratio into v_ratio from product_fractions
            where id = (v_item->>'fraction_id')::uuid;
          v_restock := (v_item->>'quantity')::numeric / coalesce(v_ratio, 1);
        else
          v_restock := (v_item->>'quantity')::numeric;
        end if;

        update product_variants set stock_quantity = stock_quantity + v_restock
          where id = v_variant.id;

        insert into inventory_movements (variant_id, change_qty, reason, ref_type, ref_id)
        values (v_variant.id, v_restock, 'RETURN', 'bill', p_bill_id);
      end if;
    end if;
  end loop;

  if p_full_return then
    update bills set status = 'CANCELLED' where id = p_bill_id;
  end if;

  -- บิลเครดิต: ลดยอดหนี้ลูกค้าแทนการคืนเงินสด (ตรงกับ logic ฝั่งแอป)
  if upper(v_bill.payment_method) = 'CREDIT' and v_bill.customer_id is not null then
    update customers set debt = greatest(0, debt - v_refund_total) where id = v_bill.customer_id;
  else
    insert into cash_ledger (shift_id, type, income, expense, description, ref_id)
    values (v_bill.shift_id, 'expense-refund', 0, v_refund_total, 'คืนสินค้าบิล ' || v_bill.bill_number, p_bill_id::text);
  end if;

  return jsonb_build_object('refund_total', v_refund_total);
end;
$$;

-- ============================================================================
-- 19c. RPC: receive_customer_payment(p_customer_id, p_amount, p_shift_id)
-- ----------------------------------------------------------------------------
-- เดิมการรับชำระหนี้ลูกค้า (window.confirmReceivePayment ในแอป) ลดยอด debt แบบ local-only
-- แล้วปล่อยให้รอบ sync สินค้า/ลูกค้าแบบเต็ม (syncProductsToSupabase → upsert customers) เป็นตัว
-- ส่งค่าขึ้น Supabase — ปัญหาคือรอบ sync นั้นส่ง "ค่า debt ล่าสุดในเครื่องนี้" ทับไปตรงๆ ทุกครั้ง
-- ถ้าระหว่างนั้นเครื่องอื่นเพิ่งขายเครดิต/รับชำระไปก่อน ค่าที่ถูกต้องบน Supabase จะโดนย้อนทับด้วย
-- ค่าเก่าจากเครื่องนี้ทันที (ไม่ใช่การบวก/ลบสะสม แต่เป็นการเขียนทับด้วยสแนปช็อตที่ล้าสมัยแล้ว)
-- ย้ายมาใช้ RPC นี้แทน: ล็อกแถวลูกค้า, ลดหนี้แบบ atomic บนเซิร์ฟเวอร์โดยตรง (ไม่ผ่าน client
-- snapshot เลย), และตัดยอดที่รับจริงไม่ให้เกินยอดหนี้คงเหลือ ณ ขณะนั้น (กันรับซ้ำ/รับเกิน)
-- ============================================================================
create or replace function receive_customer_payment(
  p_customer_id uuid,
  p_amount      numeric,
  p_shift_id    uuid
) returns jsonb
language plpgsql security definer as $$
declare
  v_customer customers%rowtype;
  v_applied  numeric;
begin
  if not is_staff() then
    raise exception 'ไม่มีสิทธิ์บันทึกการรับชำระหนี้';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'จำนวนเงินที่รับชำระต้องมากกว่า 0';
  end if;

  select * into v_customer from customers where id = p_customer_id for update;
  if not found then
    raise exception 'ไม่พบลูกค้า id=%', p_customer_id;
  end if;

  -- ตัดยอดที่นำไปหักจริงไม่ให้เกินยอดหนี้คงเหลือ ณ ขณะนี้บนเซิร์ฟเวอร์ (ไม่ใช่ยอดหนี้ตามที่
  -- client เห็นตอนเปิดฟอร์ม ซึ่งอาจไม่ตรงกันแล้วถ้ามีธุรกรรมอื่นแทรกเข้ามาก่อนหน้านี้)
  v_applied := least(p_amount, v_customer.debt);

  update customers set debt = debt - v_applied where id = p_customer_id;

  insert into cash_ledger (shift_id, type, income, expense, description, ref_id)
  values (p_shift_id, 'cash-in-ar', v_applied, 0, 'รับชำระหนี้จาก ' || v_customer.name, p_customer_id::text);

  return jsonb_build_object('applied', v_applied, 'remaining_debt', v_customer.debt - v_applied);
end;
$$;

-- ============================================================================
-- 19d. RPC: adjust_stock(p_variant_id, p_mode, p_value, p_reason)
-- ----------------------------------------------------------------------------
-- ก่อนหน้านี้การ "ปรับจำนวนที่มี" ด้วยมือ (window.confirmBulkStock ในแอป) แก้ตัวเลข
-- stock_quantity ในเครื่อง แล้วปล่อยให้ syncProductsToSupabase() แบบ upsert ทั้งก้อนเป็นตัว
-- ส่งค่าขึ้น Supabase — ปัญหาเดียวกับที่ customers.debt เคยเจอ (ดู RPC 19c ด้านบน): ถ้าระหว่างนั้น
-- เครื่องอื่นเพิ่งขาย/รับของ/คืนสินค้าตัวเดียวกันไปก่อน (ผ่าน create_sale/receive_purchase_order/
-- process_return ซึ่งอัปเดตสต็อกแบบ atomic บนเซิร์ฟเวอร์แล้ว) ค่าที่ถูกต้องบน Supabase จะโดน
-- เขียนทับด้วยสแนปช็อตที่ล้าสมัยจากเครื่องนี้ทันที ย้ายมาใช้ RPC นี้แทน: ล็อกแถว variant,
-- คำนวณค่าใหม่แบบ atomic บนเซิร์ฟเวอร์ (SET = กำหนดตรงๆ, DELTA = บวก/ลบจากค่าปัจจุบัน ณ ขณะนั้น
-- บนเซิร์ฟเวอร์ ไม่ใช่จากค่าที่ client เห็นตอนเปิดฟอร์ม) แล้วบันทึกลง inventory_movements ไว้เป็น
-- หลักฐานว่าใครปรับ ปรับเมื่อไหร่ เพราะอะไร (ตรวจสอบย้อนหลังกรณีของหาย/นับผิดได้)
--
-- จำกัดสิทธิ์ไว้ที่ is_manager() ขึ้นไป (ไม่ใช่แค่ is_staff() เหมือน RPC อื่น) เพราะการ "ปรับสต็อก
-- ด้วยมือ" เป็นช่องทางเดียวที่ใช้ปิดบังของหาย/ขายไม่ลงบัญชีได้ถ้าใครก็ปรับเองได้ — ต่างจาก
-- create_sale/process_return ที่มีร่องรอยบิลกำกับอยู่แล้วโดยธรรมชาติ
-- ============================================================================
create or replace function adjust_stock(
  p_variant_id uuid,
  p_mode       text,    -- 'SET' หรือ 'DELTA'
  p_value      numeric,
  p_reason     text default null
) returns jsonb
language plpgsql security definer as $$
declare
  v_variant  product_variants%rowtype;
  v_new      numeric;
  v_change   numeric;
begin
  if not is_manager() then
    raise exception 'เฉพาะผู้จัดการขึ้นไปเท่านั้นที่ปรับจำนวนสต็อกด้วยมือได้';
  end if;
  if p_mode not in ('SET', 'DELTA') then
    raise exception 'p_mode ต้องเป็น SET หรือ DELTA เท่านั้น';
  end if;

  select * into v_variant from product_variants where id = p_variant_id for update;
  if not found then
    raise exception 'ไม่พบสินค้า variant id=%', p_variant_id;
  end if;

  v_new := case when p_mode = 'SET' then greatest(0, p_value)
                else greatest(0, v_variant.stock_quantity + p_value) end;
  v_change := v_new - v_variant.stock_quantity;

  update product_variants set stock_quantity = v_new where id = p_variant_id;

  if v_change <> 0 then
    insert into inventory_movements (variant_id, change_qty, reason, ref_type, ref_id)
    values (p_variant_id, v_change, 'ADJUSTMENT', 'manual', null);
  end if;

  return jsonb_build_object('variant_id', p_variant_id, 'new_stock', v_new, 'change', v_change);
end;
$$;

-- ============================================================================
-- 19e. RPC: factory_reset_cloud_data()
-- ----------------------------------------------------------------------------
-- ล้างข้อมูลธุรกิจทั้งหมดบนคลาวด์ (สินค้า/หมวดหมู่/ลูกค้า/ซัพพลายเออร์/บิล/กะ/ใบสั่งซื้อ/
-- ประวัติสต็อก/เจ้าหนี้การค้า) — เรียกจากปุ่ม "คืนค่าโรงงาน" ฝั่งแอปเมื่อเลือกตัวเลือก "ล้างข้อมูล
-- บนคลาวด์ด้วย" เพิ่มเติมจากการล้าง localStorage ของเครื่องนั้นๆ ตามปกติ (ดู pos-backup-restore.js)
--
-- จำกัดไว้ที่ is_owner() เท่านั้น (แรงกว่า is_manager() ของ adjust_stock ข้อ 19d — เพราะนี่ลบ
-- ข้อมูลทั้งร้านถาวร ไม่ใช่แค่ปรับตัวเลขจุดเดียว) ใช้ TRUNCATE ... CASCADE แทนการ DELETE ทีละตาราง
-- ตามลำดับ เพราะตารางพวกนี้อ้างอิงกันด้วย FK แบบ NO ACTION (ค่า default) อยู่หลายเส้นทางมาก
-- (เช่น bill_items อ้าง product_variants ตรงๆ โดยไม่มี cascade) การไล่ DELETE เองทีละตารางเสี่ยง
-- ลำดับผิดแล้ว FK constraint ฟ้อง — TRUNCATE CASCADE ให้ Postgres ไล่ dependency graph ให้เองทั้งหมด
--
-- "จงใจไม่ลบ" แถว app_users ของเจ้าของร้านที่กำลังเรียกฟังก์ชันนี้อยู่ (auth_user_id = auth.uid())
-- เพื่อไม่ให้เจ้าของร้านล็อกตัวเองออกจากระบบไปเลยหลังล้างข้อมูล — พนักงานคนอื่นทั้งหมดถูกลบทิ้ง
--
-- ข้อจำกัดที่ทราบอยู่: บัญชี Supabase Auth สังเคราะห์ของพนักงานที่ถูกลบ (auth.users ที่
-- window.provisionEmployeeAuthAccount สร้างไว้) จะกลายเป็นบัญชีกำพร้าค้างอยู่ใน auth.users
-- ต่อไป — ไม่ได้ลบตามไปด้วยในฟังก์ชันนี้ เพราะการแก้ไข auth.users ตรงๆ อาจพฤติกรรมไม่แน่นอนต่าง
-- กันไปตามเวอร์ชัน/การตั้งค่าของแต่ละโปรเจกต์ Supabase บัญชีกำพร้าเหล่านี้ไม่มีอันตราย เพราะ
-- is_staff()/is_manager()/is_owner() เช็คผ่าน app_users ที่ถูกลบไปแล้ว จึงไม่มีสิทธิ์อะไรเหลืออยู่เลย
create or replace function factory_reset_cloud_data()
returns void
language plpgsql security definer as $$
begin
  if not is_owner() then
    raise exception 'เฉพาะเจ้าของร้าน (OWNER) เท่านั้นที่ล้างข้อมูลทั้งหมดบนคลาวด์ได้';
  end if;

  truncate table
    bill_items, bills,
    purchase_order_items, purchase_orders,
    accounts_payable, cash_ledger, inventory_movements,
    product_fractions, product_variants, product_categories, products,
    categories, customers, suppliers, shifts
    cascade;

  delete from app_users where auth_user_id is distinct from auth.uid();
end;
$$;


-- ============================================================================
-- 20. STORAGE BUCKETS  (ตรงกับ client.storage.from(...) ที่แอปเรียกใช้จริง)
-- ============================================================================
-- product-images: bucket ต้องเป็น public=true เพื่อให้ getPublicUrl() ที่แอปใช้ใช้งานได้จริง —
-- เดิมใช้ "on conflict do nothing" ซึ่งถ้า bucket นี้เคยถูกสร้างไว้ก่อนแล้ว (เช่น สร้างเองผ่าน
-- Supabase dashboard ตอนทดลองใช้งานครั้งแรก) แบบ private โดยไม่ได้ตั้งใจ การรันสคริปต์นี้ซ้ำจะ
-- "ข้าม" ไปเฉยๆ ไม่ทำให้ bucket กลายเป็น public ตามที่ตั้งใจไว้เลย — รูปสินค้าที่อัปโหลดสำเร็จและ
-- มี image_url ในตาราง products ถูกต้องแล้วก็จะยังโหลดไม่ขึ้นในแอป (ได้ 400/403 แบบเงียบๆ เพราะ
-- แอปมี onerror ที่แทนที่รูปเสียด้วยไอคอน 📦 ให้ทันที ดูเหมือน "ไม่มีรูป" ทั้งที่จริงคือโหลดรูปไม่ผ่าน)
-- เปลี่ยนเป็น "on conflict do update" บังคับตั้ง public=true ทุกครั้งที่รันสคริปต์นี้แทน
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do update set public = excluded.public;

insert into storage.buckets (id, name, public)
values ('delivery-notes', 'delivery-notes', false)
on conflict (id) do nothing;

-- product-images: เปิดอ่านสาธารณะ (แอปใช้ getPublicUrl ตรงๆ ไม่ผ่าน signed URL)
-- แต่อัปโหลด/แก้ไข/ลบได้เฉพาะพนักงานที่ล็อกอินแล้วเท่านั้น
drop policy if exists "public_read_product_images" on storage.objects;
drop policy if exists "staff_write_product_images" on storage.objects;
drop policy if exists "staff_update_product_images" on storage.objects;
drop policy if exists "staff_delete_product_images" on storage.objects;
create policy "public_read_product_images" on storage.objects
  for select using (bucket_id = 'product-images');
create policy "staff_write_product_images" on storage.objects
  for insert with check (bucket_id = 'product-images' and is_staff());
create policy "staff_update_product_images" on storage.objects
  for update using (bucket_id = 'product-images' and is_staff());
create policy "staff_delete_product_images" on storage.objects
  for delete using (bucket_id = 'product-images' and is_staff());

-- delivery-notes: หลักฐานทางบัญชี ไม่เปิดสาธารณะ — พนักงานที่ล็อกอินแล้วอ่าน/อัปโหลด/ลบได้
drop policy if exists "staff_read_delivery_notes" on storage.objects;
drop policy if exists "staff_write_delivery_notes" on storage.objects;
drop policy if exists "staff_delete_delivery_notes" on storage.objects;
create policy "staff_read_delivery_notes" on storage.objects
  for select using (bucket_id = 'delivery-notes' and is_staff());
create policy "staff_write_delivery_notes" on storage.objects
  for insert with check (bucket_id = 'delivery-notes' and is_staff());
-- เดิมก็ไม่มี DELETE policy สำหรับ bucket นี้เหมือนกัน — เพิ่มไว้ให้ครบด้วยเผื่อใช้ในอนาคต
-- (ตอนนี้แอปยังไม่มีปุ่มลบเอกสารรับสินค้าในหน้าไหนเลย แต่ไม่ควรมี gap แบบเดียวกันซ้ำอีก)
create policy "staff_delete_delivery_notes" on storage.objects
  for delete using (bucket_id = 'delivery-notes' and is_staff());

-- ============================================================================
-- หมายเหตุสำคัญที่ควรรู้ก่อนใช้งานจริง
-- ============================================================================
-- 1. รหัส id ทุกตารางเป็น uuid — แอปฝั่ง client ใช้ฟังก์ชัน toUUID() แปลง id แบบ string เดิม
--    (เช่น "cat-172...") เป็น uuid v5 มาตรฐานตาม RFC 4122 จริง (namespace คงที่ + SHA-1
--    แบบ pure-JS synchronous) เป็น deterministic คือ string เดิมแปลงแล้วได้ uuid เดิมเสมอ
-- 2. customers.debt (ยอดหนี้ค้างชำระ) มีอยู่แล้วในตาราง customers (เพิ่มไว้ในข้อ 6) — เป็น
--    แหล่งความจริงหลักเดียวของยอดหนี้ อัปเดตแบบ atomic ผ่าน create_sale / process_return /
--    receive_customer_payment RPC เท่านั้น (syncProductsToSupabase() ฝั่งแอปตั้งใจไม่ push
--    คอลัมน์นี้ขึ้นมาอีกแล้ว เพื่อไม่ให้ค่าเก่าจากเครื่องหนึ่งไปเขียนทับค่าล่าสุดที่เครื่องอื่นอัปเดตไว้
--    ผ่าน RPC — ฝั่ง pull จะดึงค่านี้จาก Supabase มาเขียนทับ local เสมอ)
-- 3. cash_ledger (ข้อ 14) เชื่อมกับแอปแล้วผ่าน syncTransactionsToSupabase() — sync รายการ
--    รับชำระหนี้/คืนเงิน และเงินเข้า-ออกที่บันทึกมือระหว่างกะ ส่วนยอดเจ้าหนี้การค้า
--    (ACCOUNTS_PAYABLE) ย้ายไปอยู่ตาราง accounts_payable (ข้อ 14b) ต่างหากแล้ว
-- 4. accounts_payable (ข้อ 14b) เป็นตารางใหม่ — เก็บยอดหนี้ที่ร้านค้างจ่ายซัพพลายเออร์จาก
--    การรับสินค้าเข้าคลัง (window.confirmReceivePO) รวมถึงสถานะจ่ายแล้ว/ยังไม่จ่าย ที่มา
--    จาก window.markAPPaid ฝั่งแอป
-- 5. parent_id ของ categories (ข้อ 1) เช่นเดียวกัน — เพิ่มไว้รองรับ แต่โค้ด sync
--    ปัจจุบันยังไม่ส่งค่านี้ขึ้นมา
-- 6. product-images bucket ต้อง public=true จึงจะโหลดรูปในแอปได้ (ดูคอมเมนต์ตรง section 20
--    ด้านบน) ถ้าเคยสร้าง bucket นี้ไว้ก่อนหน้าแบบ private ต้องรันสคริปต์นี้ซ้ำอีกครั้งหลังแก้
--    (ใช้ on conflict do update แล้ว) เพื่อบังคับให้เป็น public จริง มิฉะนั้นรูปจะโหลดไม่ขึ้นเงียบๆ
-- 7. product_variants.stock_quantity เช่นเดียวกับ customers.debt (ข้อ 2) — เป็นแหล่งความจริงหลัก
--    บน Supabase, อัปเดตแบบ atomic ผ่าน create_sale / process_return / receive_purchase_order /
--    adjust_stock (ข้อ 19d) เท่านั้น syncProductsToSupabase() ฝั่งแอปตั้งใจไม่ push คอลัมน์นี้ขึ้นมา
--    อีกแล้ว ด้วยเหตุผลเดียวกับ debt เป๊ะๆ (กันเครื่องหนึ่งเขียนทับสต็อกล่าสุดที่เครื่องอื่นเพิ่งขาย/
--    รับของ/ปรับไปด้วยสแนปช็อตเก่าของตัวเอง) ฝั่ง pull ก็ต้องดึงค่านี้จาก Supabase มาเขียนทับ local
--    เสมอสำหรับสินค้าที่มีอยู่แล้ว ไม่ใช่แค่สินค้าที่เพิ่งพบใหม่ — ดูโค้ดฝั่งแอปที่แก้คู่กัน
-- ============================================================================

-- ============================================================================
-- 21. PATCH: รองรับสินค้าหลายขนาดที่มีรหัส (SKU) และรูปภาพแยกจากสินค้าหลักได้
-- ----------------------------------------------------------------------------
-- เดิม product_variants ไม่มีคอลัมน์ sku/image_url ของตัวเอง — ทุกขนาดในสินค้าเดียวกัน
-- ใช้ sku และรูปของ products (สินค้าหลัก) ร่วมกันหมด ทำให้แยกสต็อกแยกรหัสต่อขนาดไม่ได้จริง
-- (กรณี "กระดาษกาวย่น 1 นิ้ว" / "กระดาษกาวย่น 1-1/2 นิ้ว" ที่ร้านใช้คนละรหัสต่อขนาด)
--
-- เพิ่มแบบไม่กระทบของเดิม (additive เท่านั้น): sku/image_url เป็น NULL ได้ — ถ้าเว้นว่างไว้
-- แปลว่าขนาดนั้น "ใช้รหัส/รูปเดียวกับสินค้าหลัก" ตามที่ตั้งใจไว้ ถ้าใส่ค่าแปลว่า "ขนาดนี้มีรหัส/
-- รูปของตัวเอง แยกจากสินค้าหลัก" — sku ไม่บังคับ unique ข้ามทั้งตาราง products+product_variants
-- รวมกัน เพราะ Postgres ทำ unique constraint ข้ามสองตารางไม่ได้ตรงๆ ฝั่งแอปเป็นคนกันไม่ให้ชนกันเอง
-- ============================================================================
alter table product_variants add column if not exists sku text;
alter table product_variants add column if not exists image_url text;
drop index if exists idx_product_variants_sku;
create unique index idx_product_variants_sku on product_variants(sku) where sku is not null;


-- ============================================================================
-- 21. V3 PATCH — ระบบลบข้อมูล / ประวัติการใช้งาน (audit) / ป้องกันการแก้สิทธิ์พนักงานฝั่งเซิร์ฟเวอร์
-- ----------------------------------------------------------------------------
-- รันซ้ำได้ปลอดภัย (idempotent) — วางต่อท้าย pos_schema.sql เดิมแล้วรันทั้งไฟล์ หรือรันเฉพาะไฟล์นี้กับฐานข้อมูลที่ติดตั้งไว้แล้วก็ได้
-- ต้องรันก่อนใช้งานแอป pos-app-v3.html: ปุ่มลบ/รวมสินค้าซ้ำ และหน้า "ประวัติการใช้งาน (คลาวด์)" ต้องอาศัยของในไฟล์นี้
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 21.1  คอลัมน์ is_active เพิ่มเติม — ใช้ "เก็บเข้าประวัติ" แทนการลบถาวรเมื่อรายการนั้นมีธุรกรรมผูกอยู่
--       (products / product_variants / app_users มี is_active อยู่แล้วจากไฟล์เดิม)
-- ----------------------------------------------------------------------------
alter table customers        add column if not exists is_active boolean not null default true;
alter table suppliers        add column if not exists is_active boolean not null default true;
alter table product_fractions add column if not exists is_active boolean not null default true;

-- ----------------------------------------------------------------------------
-- 21.2  audit_logs — ประวัติการเข้าใช้และการทำรายการ (เพิ่มได้อย่างเดียว แก้/ลบไม่ได้แม้เป็นเจ้าของร้าน)
--       actor_app_user_id ตั้งใจ "ไม่" ทำ foreign key: กันไม่ให้การลบพนักงานไปแตะประวัติ และประวัติคงอยู่แม้พนักงานถูกลบ
--       received_by = บัญชี Supabase ที่ส่งแถวนี้เข้ามาจริง (เซิร์ฟเวอร์ใส่ให้เอง) — ใช้เทียบกับ actor_name ตอนตรวจสอบ
--       ข้อควรรู้: แอปเป็นผู้ระบุ actor_name เอง (เซิร์ฟเวอร์ไม่รู้ว่าใครกด PIN) จึงเทียบกับ received_by ได้ว่าเครื่อง/บัญชีไหนส่งมา
-- ----------------------------------------------------------------------------
create table if not exists audit_logs (
  id                 uuid primary key,
  occurred_at        timestamptz not null default now(),
  actor_app_user_id  uuid,
  actor_name         text,
  actor_role         text,
  action             text not null,
  entity             text,
  entity_id          text,
  detail             text,
  meta               jsonb,
  device_id          text,
  received_at        timestamptz not null default now(),
  received_by        uuid default auth.uid()
);
create index if not exists idx_audit_occurred on audit_logs(occurred_at desc);
create index if not exists idx_audit_actor    on audit_logs(actor_name, occurred_at desc);
create index if not exists idx_audit_action   on audit_logs(action, occurred_at desc);
create index if not exists idx_audit_entity   on audit_logs(entity, entity_id);

alter table audit_logs enable row level security;
drop policy if exists "staff_insert_audit_logs"   on audit_logs;
drop policy if exists "manager_select_audit_logs" on audit_logs;
create policy "staff_insert_audit_logs"   on audit_logs for insert with check (is_staff());
create policy "manager_select_audit_logs" on audit_logs for select using (is_manager());
-- ไม่มี policy update/delete = ถูกปฏิเสธทุกกรณี; trigger ด้านล่างกันซ้ำอีกชั้น (รวมผู้ใช้ที่ข้าม RLS ได้ และ TRUNCATE)
create or replace function audit_logs_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_logs เป็นประวัติแบบเพิ่มได้อย่างเดียว ห้ามแก้ไข/ลบ';
end;
$$;
drop trigger if exists trg_audit_logs_no_update   on audit_logs;
drop trigger if exists trg_audit_logs_no_truncate on audit_logs;
create trigger trg_audit_logs_no_update   before update or delete on audit_logs for each row       execute function audit_logs_immutable();
create trigger trg_audit_logs_no_truncate before truncate          on audit_logs for each statement execute function audit_logs_immutable();

-- ----------------------------------------------------------------------------
-- 21.3  has_perm(p) — ผู้จัดการ/เจ้าของมีทุกสิทธิ์ แคชเชียร์มีเฉพาะที่เจ้าของติ๊กให้ (app_users.permissions)
-- ----------------------------------------------------------------------------
create or replace function has_perm(p_perm text) returns boolean
language sql security definer stable as $$
  select exists (
    select 1 from app_users
    where auth_user_id = auth.uid() and is_active
      and (role in ('OWNER','MANAGER') or coalesce(permissions, '[]'::jsonb) @> to_jsonb(p_perm))
  );
$$;

-- ----------------------------------------------------------------------------
-- 21.4  RPC: delete_entity(p_kind, p_id, p_note)
--   ลบข้อมูลจากฝั่งแอป โดยเลือกให้อัตโนมัติ:
--     • มีธุรกรรมผูกอยู่ (บิล / ใบสั่งซื้อ / ประวัติสต็อก)  → "เก็บเข้าประวัติ" (is_active=false) ผลลัพธ์ mode='archived'
--       และปล่อยรหัส SKU/บาร์โค้ดที่เป็น unique ให้กลับไปใช้ใหม่ได้ (ต่อท้าย #arch-xxxx / ตั้งบาร์โค้ดเป็น NULL)
--     • ไม่มีธุรกรรม                                    → ลบถาวร                    ผลลัพธ์ mode='deleted'
--     • ไม่พบข้อมูลบนคลาวด์                             →                            ผลลัพธ์ mode='missing'
--   kind ที่รองรับ: product, variant, fraction, category, customer, supplier, purchase_order, employee
-- ----------------------------------------------------------------------------
create or replace function delete_entity(p_kind text, p_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer as $$
declare
  v_mode      text := 'deleted';
  v_has_hist  boolean;
  v_row       record;
  v_me        app_users%rowtype;
  v_tag       text := '#arch-' || left(p_id::text, 8);
begin
  if not is_staff() then
    raise exception 'ต้องเข้าสู่ระบบเป็นพนักงานก่อน';
  end if;
  select * into v_me from app_users where auth_user_id = auth.uid() and is_active limit 1;

  if p_kind in ('product','variant','fraction','category') then
    if not has_perm('products.delete') then raise exception 'ไม่มีสิทธิ์ลบสินค้า/หมวดหมู่ (products.delete)'; end if;
  elsif p_kind = 'customer' then
    if not has_perm('customers.delete') then raise exception 'ไม่มีสิทธิ์ลบลูกค้า (customers.delete)'; end if;
  elsif p_kind in ('supplier','purchase_order') then
    if not has_perm('suppliers.manage') then raise exception 'ไม่มีสิทธิ์จัดการซัพพลายเออร์/ใบสั่งซื้อ (suppliers.manage)'; end if;
  elsif p_kind = 'employee' then
    if not has_perm('employees.manage') then raise exception 'ไม่มีสิทธิ์จัดการพนักงาน (employees.manage)'; end if;
  else
    raise exception 'ไม่รู้จักชนิดข้อมูลที่จะลบ: %', p_kind;
  end if;

  -- ---------------- product ----------------
  if p_kind = 'product' then
    if not exists (select 1 from products where id = p_id) then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    v_has_hist :=
         exists (select 1 from bill_items where product_id = p_id)
      or exists (select 1 from purchase_order_items where product_id = p_id)
      or exists (select 1 from inventory_movements m join product_variants v on v.id = m.variant_id where v.product_id = p_id);
    if v_has_hist then
      update products set is_active = false,
             sku = case when sku is null then null when sku like '%#arch-%' then sku else sku || v_tag end
       where id = p_id;
      update product_variants set is_active = false, barcode = null,
             sku = case when sku is null then null when sku like '%#arch-%' then sku else sku || '#arch-' || left(id::text, 8) end
       where product_id = p_id;
      update product_fractions set is_active = false where variant_id in (select id from product_variants where product_id = p_id);
      v_mode := 'archived';
    else
      delete from products where id = p_id;  -- variants / fractions / product_categories ถูกลบตามด้วย ON DELETE CASCADE
    end if;

  -- ---------------- variant ----------------
  elsif p_kind = 'variant' then
    if not exists (select 1 from product_variants where id = p_id) then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    v_has_hist :=
         exists (select 1 from bill_items where variant_id = p_id)
      or exists (select 1 from purchase_order_items where variant_id = p_id)
      or exists (select 1 from inventory_movements where variant_id = p_id);
    if v_has_hist then
      update product_variants set is_active = false, barcode = null,
             sku = case when sku is null then null when sku like '%#arch-%' then sku else sku || v_tag end
       where id = p_id;
      update product_fractions set is_active = false where variant_id = p_id;
      v_mode := 'archived';
    else
      delete from product_variants where id = p_id;
    end if;

  -- ---------------- fraction (หน่วยแบ่งขาย) ----------------
  elsif p_kind = 'fraction' then
    if not exists (select 1 from product_fractions where id = p_id) then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    if exists (select 1 from bill_items where fraction_id = p_id) then
      update product_fractions set is_active = false where id = p_id;
      v_mode := 'archived';
    else
      delete from product_fractions where id = p_id;
    end if;

  -- ---------------- category ----------------
  elsif p_kind = 'category' then
    if not exists (select 1 from categories where id = p_id) then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    delete from categories where id = p_id;  -- product_categories ถูกลบตาม, หมวดลูกจะถูกตั้ง parent_id = NULL

  -- ---------------- customer ----------------
  elsif p_kind = 'customer' then
    select * into v_row from customers where id = p_id;
    if not found then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    if coalesce(v_row.debt, 0) > 0 then raise exception 'ลูกค้า "%" ยังมีหนี้ค้าง % บาท — ต้องรับชำระให้หมดก่อนถึงจะลบได้', v_row.name, v_row.debt; end if;
    if exists (select 1 from bills where customer_id = p_id) then
      update customers set is_active = false where id = p_id; v_mode := 'archived';
    else
      delete from customers where id = p_id;
    end if;

  -- ---------------- supplier ----------------
  elsif p_kind = 'supplier' then
    if not exists (select 1 from suppliers where id = p_id) then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    if exists (select 1 from purchase_orders where supplier_id = p_id) or exists (select 1 from accounts_payable where supplier_id = p_id) then
      update suppliers set is_active = false where id = p_id; v_mode := 'archived';
    else
      delete from suppliers where id = p_id;
    end if;

  -- ---------------- purchase_order ----------------
  elsif p_kind = 'purchase_order' then
    select * into v_row from purchase_orders where id = p_id;
    if not found then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    if v_row.status = 'RECEIVED' or exists (select 1 from purchase_order_items where purchase_order_id = p_id and coalesce(received_quantity, 0) > 0) then
      raise exception 'ใบสั่งซื้อ % รับสินค้าเข้าคลังแล้ว ลบไม่ได้ (มีประวัติสต็อกผูกอยู่)', v_row.po_number;
    end if;
    delete from purchase_orders where id = p_id;  -- purchase_order_items ถูกลบตาม, accounts_payable.purchase_order_id ตั้งเป็น NULL

  -- ---------------- employee ----------------
  elsif p_kind = 'employee' then
    select * into v_row from app_users where id = p_id;
    if not found then return jsonb_build_object('mode','missing','kind',p_kind); end if;
    if v_row.role = 'OWNER' then raise exception 'ลบเจ้าของร้านไม่ได้'; end if;
    if v_row.id = v_me.id then raise exception 'ลบบัญชีของตัวเองไม่ได้'; end if;
    if v_me.role <> 'OWNER' and v_row.role <> 'CASHIER' then raise exception 'ผู้จัดการลบได้เฉพาะบัญชีแคชเชียร์'; end if;
    if exists (select 1 from bills where user_id = p_id) or exists (select 1 from shifts where opened_by = p_id or closed_by = p_id) then
      update app_users set is_active = false where id = p_id; v_mode := 'archived';   -- มีประวัติขาย/กะ → ปิดใช้งานแทนลบ
    else
      delete from app_users where id = p_id;
    end if;
  end if;

  -- ประวัติฝั่งเซิร์ฟเวอร์ (แหล่งความจริง แม้เครื่องลูกจะไม่ได้ส่งประวัติของตัวเองขึ้นมา)
  insert into audit_logs (id, actor_app_user_id, actor_name, actor_role, action, entity, entity_id, detail, meta, device_id)
  values (gen_random_uuid(), v_me.id, v_me.name, v_me.role, 'SERVER_DELETE', p_kind, p_id::text,
          coalesce(p_note, '') || ' → ' || case v_mode when 'archived' then 'เก็บเข้าประวัติ' else 'ลบถาวร' end,
          jsonb_build_object('mode', v_mode), 'server');

  return jsonb_build_object('mode', v_mode, 'kind', p_kind);
end;
$$;

-- ----------------------------------------------------------------------------
-- 21.5  ป้องกันการแก้ตำแหน่ง/สิทธิ์พนักงานเกินอำนาจ (ฝั่งเซิร์ฟเวอร์ — แอปฝั่งเครื่องแค่ซ่อนปุ่ม ยังไม่พอ)
--       policy เดิมให้ "ผู้จัดการ" เขียนตาราง app_users ได้ทุกแถว รวมถึงแถวเจ้าของร้านและการเลื่อนตำแหน่งตัวเอง
--       กติกา: ผู้จัดการเพิ่ม/แก้/ลบได้เฉพาะบัญชี CASHIER (และห้ามเปลี่ยนใครเป็น MANAGER/OWNER) — เจ้าของทำได้ทุกอย่าง
--       ยกเว้น: ตอนยังไม่มีเจ้าของเลย (bootstrap_first_owner) และคำสั่งที่รันจาก SQL editor / service role (auth.uid() เป็น NULL)
-- ----------------------------------------------------------------------------
create or replace function guard_app_users_change() returns trigger
language plpgsql as $$
begin
  if auth.uid() is null or is_owner() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'INSERT' then
    if new.role = 'OWNER' and not exists (select 1 from app_users where role = 'OWNER') then return new; end if;
    if new.role <> 'CASHIER' then raise exception 'เฉพาะเจ้าของร้านเท่านั้นที่เพิ่มบัญชีผู้จัดการ/เจ้าของได้'; end if;
    return new;
  elsif tg_op = 'UPDATE' then
    if old.role <> 'CASHIER' or new.role <> 'CASHIER' then raise exception 'เฉพาะเจ้าของร้านเท่านั้นที่แก้ไขบัญชีผู้จัดการ/เจ้าของ หรือเปลี่ยนตำแหน่งได้'; end if;
    return new;
  else
    if old.role <> 'CASHIER' then raise exception 'เฉพาะเจ้าของร้านเท่านั้นที่ลบบัญชีผู้จัดการ/เจ้าของได้'; end if;
    return old;
  end if;
end;
$$;
drop trigger if exists trg_guard_app_users on app_users;
create trigger trg_guard_app_users before insert or update or delete on app_users for each row execute function guard_app_users_change();

-- ----------------------------------------------------------------------------
-- 21.6  factory_reset_cloud_data() — ปุ่ม "ล้างข้อมูลในเครื่อง + คลาวด์" ในแอปเรียกตัวนี้
--       เหมือนของเดิม (เจ้าของร้านเท่านั้น ล้างทุกตารางข้อมูล ลบพนักงานอื่นทั้งหมด) แต่เพิ่มการบันทึกลง audit_logs ว่าใครล้าง
--       audit_logs "ไม่ถูกล้าง" ตั้งใจ: เป็นหลักฐานย้อนหลังว่าเคยมีการล้างข้อมูล (และไม่มี FK จึงไม่ถูก TRUNCATE ... CASCADE ลากไปด้วย)
-- ----------------------------------------------------------------------------
create or replace function factory_reset_cloud_data()
returns void
language plpgsql security definer as $$
declare
  v_me app_users%rowtype;
begin
  if not is_owner() then
    raise exception 'เฉพาะเจ้าของร้าน (OWNER) เท่านั้นที่ล้างข้อมูลทั้งหมดบนคลาวด์ได้';
  end if;
  select * into v_me from app_users where auth_user_id = auth.uid() limit 1;

  truncate table
    bill_items, bills,
    purchase_order_items, purchase_orders,
    accounts_payable, cash_ledger, inventory_movements,
    product_fractions, product_variants, product_categories, products,
    categories, customers, suppliers, shifts
    cascade;

  delete from app_users where auth_user_id is distinct from auth.uid();

  insert into audit_logs (id, actor_app_user_id, actor_name, actor_role, action, entity, entity_id, detail, meta, device_id)
  values (gen_random_uuid(), v_me.id, v_me.name, v_me.role, 'SERVER_RESET', 'system', null,
          'ล้างข้อมูลทั้งหมดบนคลาวด์ (คงไว้เฉพาะบัญชีเจ้าของร้านและประวัติการใช้งาน)', null, 'server');
end;
$$;
