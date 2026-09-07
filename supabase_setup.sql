create extension if not exists pgcrypto;
create table if not exists public.admins(user_id uuid primary key references auth.users(id) on delete cascade);
create table if not exists public.referral_codes(code text primary key,owner_name text not null,owner_phone text not null,created_at timestamptz default now(),reward_credits integer not null default 0);
create table if not exists public.bookings(
 id uuid primary key default gen_random_uuid(),customer_name text not null,customer_phone text not null,
 items jsonb not null,student boolean not null default false,first_booking boolean not null default false,
 referral_code_used text references public.referral_codes(code),customer_referral_code text not null unique references public.referral_codes(code),
 subtotal numeric(10,2) not null,discount_amount numeric(10,2) not null default 0,total_amount numeric(10,2) not null,
 booking_date date not null,booking_time time not null,address text not null,
 payment_status text not null default 'PENDING' check(payment_status in ('PENDING','PAID')),
 paid_at timestamptz,created_at timestamptz default now());
alter table public.admins enable row level security;alter table public.referral_codes enable row level security;alter table public.bookings enable row level security;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from public.admins where user_id=auth.uid())$$;
create policy "admin referral access" on public.referral_codes for all using(public.is_admin()) with check(public.is_admin());
create policy "admin booking access" on public.bookings for all using(public.is_admin()) with check(public.is_admin());
create or replace function public.make_referral_code(p_name text,p_phone text) returns text language plpgsql security definer set search_path=public as $$
declare c text;begin loop c:='ADRON-'||upper(substr(encode(gen_random_bytes(3),'hex'),1,4))||'-'||upper(substr(encode(gen_random_bytes(3),'hex'),1,4));exit when not exists(select 1 from public.referral_codes where code=c);end loop;insert into public.referral_codes(code,owner_name,owner_phone) values(c,p_name,p_phone);return c;end$$;
create or replace function public.create_booking(p_name text,p_phone text,p_items jsonb,p_student boolean,p_first_booking boolean,p_referral_code text,p_date date,p_time time,p_address text) returns public.bookings language plpgsql security definer set search_path=public as $$
declare r public.referral_codes;b public.bookings;v_sub numeric:=0;v_discount numeric:=0;v_total numeric:=0;v_rate numeric:=0;v_code text;
begin if coalesce(trim(p_name),'')='' or coalesce(trim(p_phone),'')='' or coalesce(trim(p_address),'')='' then raise exception 'Name, phone and address are required';end if;if jsonb_array_length(p_items)=0 then raise exception 'Select at least one service';end if;
select coalesce(sum((x->>'price')::numeric*greatest(1,(x->>'quantity')::numeric)),0) into v_sub from jsonb_array_elements(p_items)x;
v_rate:=case when p_student or p_first_booking then 10 else 0 end;
if p_referral_code is not null and trim(p_referral_code)<>'' then select * into r from public.referral_codes where code=upper(trim(p_referral_code));if not found then raise exception 'Invalid referral code';end if;if r.owner_phone=regexp_replace(p_phone,'\D','','g') then raise exception 'You cannot use your own referral code';end if;end if;
v_discount:=round(v_sub*v_rate/100,2);v_total:=v_sub-v_discount;v_code:=public.make_referral_code(p_name,regexp_replace(p_phone,'\D','','g'));
insert into public.bookings(customer_name,customer_phone,items,student,first_booking,referral_code_used,customer_referral_code,subtotal,discount_amount,total_amount,booking_date,booking_time,address)
values(p_name,regexp_replace(p_phone,'\D','','g'),p_items,p_student,p_first_booking,nullif(upper(trim(p_referral_code)),''),v_code,v_sub,v_discount,v_total,p_date,p_time,p_address) returning * into b;return b;end$$;
grant execute on function public.create_booking(text,text,jsonb,boolean,boolean,text,date,time,text) to anon,authenticated;
create or replace function public.admin_list_bookings() returns setof public.bookings language sql security definer set search_path=public as $$select * from public.bookings where public.is_admin() order by created_at desc$$;grant execute on function public.admin_list_bookings() to authenticated;
create or replace function public.mark_booking_paid(p_booking_id uuid) returns public.bookings language plpgsql security definer set search_path=public as $$
declare b public.bookings;begin if not public.is_admin() then raise exception 'Not authorized';end if;update public.bookings set payment_status='PAID',paid_at=coalesce(paid_at,now()) where id=p_booking_id and payment_status='PENDING' returning * into b;if not found then raise exception 'Booking not found or already paid';end if;if b.referral_code_used is not null then update public.referral_codes set reward_credits=reward_credits+10 where code=b.referral_code_used;end if;return b;end$$;grant execute on function public.mark_booking_paid(uuid) to authenticated;
revoke all on public.bookings from anon,authenticated;revoke all on public.referral_codes from anon,authenticated;revoke all on public.admins from anon,authenticated;
-- After creating your admin user, run:
-- insert into public.admins(user_id) values ('YOUR_ADMIN_AUTH_USER_UUID') on conflict do nothing;
