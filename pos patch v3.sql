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
