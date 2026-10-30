-- INNOVANET · Ejecutar COMPLETO en Supabase SQL Editor con usuario administrador.
-- IMPORTANTE: posteriormente asignar el primer administrador conforme a README.md.
create extension if not exists pgcrypto;

create table if not exists public.perfiles (
 id uuid primary key references auth.users(id) on delete cascade,
 nombre text not null default 'Usuario', correo text not null default '',
 rol text not null default 'operador' check(rol in ('administrador','operador','consulta')),
 activo boolean not null default true, creado_en timestamptz not null default now()
);
create table if not exists public.permisos (
 rol text not null check(rol in ('administrador','operador','consulta')),
 modulo text not null check(modulo in ('inicio','documentos','clientes','productos','monedas','cai','empresa','usuarios')),
 permitido boolean not null default false, primary key(rol,modulo)
);
insert into public.permisos(rol,modulo,permitido)
select r.rol,m.modulo,case when r.rol='administrador' then true when r.rol='operador' then m.modulo in ('inicio','documentos','clientes','productos','monedas') else m.modulo in ('inicio','documentos') end
from (values('administrador'),('operador'),('consulta')) r(rol)
cross join (values('inicio'),('documentos'),('clientes'),('productos'),('monedas'),('cai'),('empresa'),('usuarios')) m(modulo)
on conflict (rol,modulo) do nothing;

create table if not exists public.empresa (
 id integer primary key default 1 check(id=1), nombre text not null default 'INNOVANET',
 razon_social text not null default '', rtn text not null default '', direccion text not null default '',
 telefono text not null default '', correo text not null default '', lema text not null default '',
 impuesto_nombre text not null default 'ISV', impuesto_pct numeric(6,2) not null default 15 check(impuesto_pct between 0 and 100),
 pie_documento text not null default 'Gracias por su preferencia.', actualizado_en timestamptz not null default now()
);
insert into public.empresa(id) values(1) on conflict do nothing;
create table if not exists public.monedas (
 codigo text primary key check(codigo ~ '^[A-Z]{3}$'), nombre text not null,
 simbolo text not null, tasa_hnl numeric(18,6) not null check(tasa_hnl>0),
 activa boolean not null default true, actualizado_en timestamptz not null default now()
);
insert into public.monedas(codigo,nombre,simbolo,tasa_hnl) values
('HNL','Lempira','L',1),('USD','Dólar estadounidense','$',1)
on conflict(codigo) do nothing;
-- Cambiar tasa USD manualmente; 1 es un MARCADOR, NO tipo de cambio real.
create table if not exists public.clientes (
 id uuid primary key default gen_random_uuid(), nombre text not null, rtn text not null default '',
 telefono text not null default '', correo text not null default '', direccion text not null default '',
 activo boolean not null default true, creado_en timestamptz not null default now()
);
create table if not exists public.productos (
 id uuid primary key default gen_random_uuid(), codigo text not null default '', nombre text not null,
 descripcion text not null default '', precio numeric(18,2) not null default 0 check(precio>=0),
 activo boolean not null default true, creado_en timestamptz not null default now()
);
create table if not exists public.autorizaciones_cai (
 id uuid primary key default gen_random_uuid(), cai text not null, establecimiento text not null,
 punto_emision text not null, tipo_documento text not null default '01',
 desde bigint not null check(desde>0), hasta bigint not null check(hasta>=desde),
 siguiente bigint not null check(siguiente>0), fecha_limite date not null,
 activa boolean not null default false, creado_en timestamptz not null default now(),
 check(establecimiento ~ '^\d{3}$' and punto_emision ~ '^\d{3}$' and tipo_documento ~ '^\d{2}$'),
 check(siguiente between desde and hasta+1)
);
create unique index if not exists unico_cai_activo on public.autorizaciones_cai(activa) where activa=true;
create table if not exists public.documentos (
 id uuid primary key default gen_random_uuid(), tipo text not null check(tipo in ('proforma','factura')),
 estado text not null check(estado in ('borrador','emitida','anulada')),
 numero text not null unique, fecha timestamptz not null default now(),
 cliente_id uuid references public.clientes(id) on delete set null,
 cliente_nombre text not null, cliente_rtn text not null default '', cliente_direccion text not null default '',
 moneda_codigo text not null references public.monedas(codigo), tasa_hnl numeric(18,6) not null,
 descuento numeric(18,2) not null default 0, impuesto_pct numeric(6,2) not null default 0,
 subtotal numeric(18,2) not null default 0, impuesto numeric(18,2) not null default 0,
 total numeric(18,2) not null default 0, observaciones text not null default '',
 cai_id uuid references public.autorizaciones_cai(id), cai_texto text,
 fecha_limite date, rango_desde bigint, rango_hasta bigint,
 empresa_snapshot jsonb not null default '{}'::jsonb,
 creado_por uuid not null references auth.users(id), creado_en timestamptz not null default now(),
 actualizado_en timestamptz not null default now()
);
create table if not exists public.documento_items (
 id uuid primary key default gen_random_uuid(), documento_id uuid not null references public.documentos(id) on delete cascade,
 producto_id uuid references public.productos(id) on delete set null, descripcion text not null,
 cantidad numeric(18,3) not null check(cantidad>0), precio numeric(18,2) not null check(precio>=0),
 total numeric(18,2) not null check(total>=0), orden integer not null
);
create index if not exists idx_documentos_fecha on public.documentos(fecha desc);
create index if not exists idx_documentos_tipo_estado on public.documentos(tipo,estado);
create index if not exists idx_doc_items_doc on public.documento_items(documento_id);
create table if not exists public.consecutivos (clave text primary key, siguiente bigint not null default 1);
insert into public.consecutivos(clave,siguiente) values('PROFORMA',1),('BORRADOR',1) on conflict do nothing;

-- Perfil creado automáticamente con Supabase Auth. Ningún usuario recibe admin por registrarse.
create or replace function public.crear_perfil() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.perfiles(id,nombre,correo) values(new.id,coalesce(nullif(new.raw_user_meta_data->>'nombre',''),split_part(coalesce(new.email,''),'@',1)),coalesce(new.email,'')) on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists trg_auth_perfil on auth.users;
create trigger trg_auth_perfil after insert on auth.users for each row execute function public.crear_perfil();

-- Las funciones de permisos se ejecutan sin exponer datos internos ni permitir autoascenso.
create or replace function public.es_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.perfiles p where p.id=auth.uid() and p.rol='administrador' and p.activo=true)
$$;
create or replace function public.tiene_permiso(p_modulo text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.perfiles p join public.permisos q on q.rol=p.rol where p.id=auth.uid() and p.activo and q.modulo=p_modulo and q.permitido)
$$;
revoke execute on function public.es_admin() from public,anon;
revoke execute on function public.tiene_permiso(text) from public,anon;
grant execute on function public.es_admin() to authenticated;
grant execute on function public.tiene_permiso(text) to authenticated;

-- RLS: sin políticas de escritura directa sobre documentos, líneas ni consecutivos.
alter table public.perfiles enable row level security;
alter table public.permisos enable row level security;
alter table public.empresa enable row level security;
alter table public.monedas enable row level security;
alter table public.clientes enable row level security;
alter table public.productos enable row level security;
alter table public.autorizaciones_cai enable row level security;
alter table public.documentos enable row level security;
alter table public.documento_items enable row level security;
alter table public.consecutivos enable row level security;
revoke all on public.perfiles,public.permisos,public.empresa,public.monedas,public.clientes,public.productos,public.autorizaciones_cai,public.documentos,public.documento_items,public.consecutivos from anon,authenticated;
grant select on public.perfiles,public.permisos,public.empresa,public.monedas,public.clientes,public.productos,public.autorizaciones_cai,public.documentos,public.documento_items to authenticated;
grant insert,update on public.clientes,public.productos,public.monedas to authenticated;
grant update on public.empresa,public.perfiles,public.permisos to authenticated;
grant insert,update on public.autorizaciones_cai to authenticated;

create policy perfiles_ver on public.perfiles for select to authenticated using(id=auth.uid() or public.es_admin());
create policy perfiles_admin_editar on public.perfiles for update to authenticated using(public.es_admin()) with check(public.es_admin());
create policy permisos_ver on public.permisos for select to authenticated using(true);
create policy permisos_admin_editar on public.permisos for update to authenticated using(public.es_admin()) with check(public.es_admin());
create policy empresa_ver on public.empresa for select to authenticated using(public.tiene_permiso('inicio') or public.tiene_permiso('documentos') or public.es_admin());
create policy empresa_editar on public.empresa for update to authenticated using(public.tiene_permiso('empresa')) with check(public.tiene_permiso('empresa'));
create policy monedas_ver on public.monedas for select to authenticated using(public.tiene_permiso('documentos') or public.tiene_permiso('monedas'));
create policy monedas_insertar on public.monedas for insert to authenticated with check(public.tiene_permiso('monedas'));
create policy monedas_editar on public.monedas for update to authenticated using(public.tiene_permiso('monedas')) with check(public.tiene_permiso('monedas'));
create policy clientes_ver on public.clientes for select to authenticated using(public.tiene_permiso('clientes') or public.tiene_permiso('documentos'));
create policy clientes_insertar on public.clientes for insert to authenticated with check(public.tiene_permiso('clientes') or public.tiene_permiso('documentos'));
create policy clientes_editar on public.clientes for update to authenticated using(public.tiene_permiso('clientes')) with check(public.tiene_permiso('clientes'));
create policy productos_ver on public.productos for select to authenticated using(public.tiene_permiso('productos') or public.tiene_permiso('documentos'));
create policy productos_insertar on public.productos for insert to authenticated with check(public.tiene_permiso('productos') or public.tiene_permiso('documentos'));
create policy productos_editar on public.productos for update to authenticated using(public.tiene_permiso('productos')) with check(public.tiene_permiso('productos'));
create policy cai_ver on public.autorizaciones_cai for select to authenticated using(public.tiene_permiso('cai') or public.tiene_permiso('documentos'));
create policy cai_insertar on public.autorizaciones_cai for insert to authenticated with check(public.tiene_permiso('cai'));
create policy cai_editar on public.autorizaciones_cai for update to authenticated using(public.tiene_permiso('cai')) with check(public.tiene_permiso('cai'));
create policy documentos_ver on public.documentos for select to authenticated using(public.tiene_permiso('documentos') or public.es_admin());
create policy lineas_ver on public.documento_items for select to authenticated using(public.tiene_permiso('documentos') or public.es_admin());

-- RPC transaccional: valida y recalcula importes, evita duplicar correlativos fiscales.
-- No acepta campo estado arbitrario ni edita facturas ya emitidas.
create or replace function public.guardar_documento(p_datos jsonb, p_items jsonb, p_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare
 v_id uuid; v_tipo text; v_estado text; v_numero text; v_cai public.autorizaciones_cai%rowtype;
 v_seq bigint; v_fila jsonb; v_q numeric; v_p numeric; v_sub numeric:=0; v_desc numeric;
 v_pct numeric; v_base numeric; v_imp numeric; v_total numeric; v_mon public.monedas%rowtype;
 v_empresa jsonb; v_cliente uuid; v_nombre text; v_rtn text; v_dir text;
 v_guardar_cliente boolean; v_creado uuid; v_actual public.documentos%rowtype;
 v_producto uuid; v_descripcion text; v_idx integer:=0; v_nuevo_producto uuid;
begin
 if not public.tiene_permiso('documentos') then raise exception 'No tiene permiso para crear documentos'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>100 then raise exception 'Debe ingresar entre 1 y 100 artículos'; end if;
 v_tipo:=p_datos->>'tipo';
 if v_tipo not in ('factura','proforma') or v_tipo is null then raise exception 'Tipo de documento inválido'; end if;
 v_nombre:=trim(coalesce(p_datos->>'cliente_nombre',''));
 if v_nombre='' or length(v_nombre)>250 then raise exception 'Indique nombre del cliente (máximo 250 caracteres)'; end if;
 v_rtn:=coalesce(p_datos->>'cliente_rtn',''); v_dir:=coalesce(p_datos->>'cliente_direccion','');
 v_desc:=round(coalesce((p_datos->>'descuento')::numeric,0),2);
 if v_desc<0 then raise exception 'Descuento inválido'; end if;
 select * into v_mon from public.monedas where codigo=p_datos->>'moneda_codigo' and activa;
 if not found then raise exception 'Moneda no disponible'; end if;
 select to_jsonb(e) into v_empresa from public.empresa e where id=1;
 if v_empresa is null then raise exception 'Configure primero la empresa'; end if;
 v_pct:=case when coalesce(p_datos->>'impuesto_pct','')<>'' then (p_datos->>'impuesto_pct')::numeric else (v_empresa->>'impuesto_pct')::numeric end;
 if v_pct<0 or v_pct>100 then raise exception 'Impuesto fuera de rango'; end if;
 v_cliente:=nullif(p_datos->>'cliente_id','')::uuid;
 if v_cliente is not null and not exists(select 1 from public.clientes where id=v_cliente) then raise exception 'Cliente inexistente'; end if;
 v_guardar_cliente:=coalesce((p_datos->>'guardar_cliente')::boolean,false);
 if v_guardar_cliente and v_cliente is null then
   insert into public.clientes(nombre,rtn,direccion,correo,telefono)
   values(v_nombre,v_rtn,v_dir,coalesce(p_datos->>'cliente_correo',''),coalesce(p_datos->>'cliente_telefono','')) returning id into v_cliente;
 end if;
 for v_fila in select value from jsonb_array_elements(p_items) loop
  v_q:=nullif(v_fila->>'cantidad','')::numeric; v_p:=nullif(v_fila->>'precio','')::numeric;
  if v_q is null or v_q<=0 or v_q>1000000 or v_p is null or v_p<0 or v_p>100000000 then raise exception 'Cantidad o precio inválido'; end if;
  if trim(coalesce(v_fila->>'descripcion',''))='' then raise exception 'Hay artículos sin descripción'; end if;
  v_sub:=v_sub+round(v_q*v_p,2);
 end loop;
 v_sub:=round(v_sub,2);
 if v_desc>v_sub then raise exception 'El descuento supera el subtotal'; end if;
 v_base:=v_sub-v_desc; v_imp:=round(v_base*v_pct/100,2); v_total:=v_base+v_imp;
 if p_id is not null then
   select * into v_actual from public.documentos where id=p_id for update;
   if not found then raise exception 'Documento no encontrado'; end if;
   if v_actual.tipo='factura' or v_actual.estado='emitida' or v_actual.estado='anulada' then raise exception 'Las facturas emitidas o anuladas no pueden modificarse'; end if;
   if v_tipo<>'proforma' then raise exception 'No puede convertir una proforma a factura mediante edición; use nueva factura'; end if;
   v_id:=p_id; v_numero:=v_actual.numero; v_estado:='borrador';
   delete from public.documento_items where documento_id=v_id;
 else
   if v_tipo='factura' then
     select * into v_cai from public.autorizaciones_cai where activa=true for update;
     if not found then raise exception 'Debe configurar un CAI activo antes de emitir facturas'; end if;
     if current_date>v_cai.fecha_limite then raise exception 'El CAI está vencido'; end if;
     if v_cai.siguiente>v_cai.hasta then raise exception 'Se agotó el rango autorizado'; end if;
     v_numero:=v_cai.establecimiento||'-'||v_cai.punto_emision||'-'||v_cai.tipo_documento||'-'||lpad(v_cai.siguiente::text,8,'0');
     update public.autorizaciones_cai set siguiente=siguiente+1 where id=v_cai.id;
     v_estado:='emitida';
   else
     update public.consecutivos set siguiente=siguiente+1 where clave='PROFORMA' returning siguiente-1 into v_seq;
     v_numero:='PRO-'||lpad(v_seq::text,7,'0'); v_estado:='borrador';
   end if;
   v_id:=gen_random_uuid();
 end if;
 if p_id is not null then
  update public.documentos set cliente_id=v_cliente,cliente_nombre=v_nombre,cliente_rtn=v_rtn,cliente_direccion=v_dir,
  moneda_codigo=v_mon.codigo,tasa_hnl=v_mon.tasa_hnl,descuento=v_desc,impuesto_pct=v_pct,
  subtotal=v_sub,impuesto=v_imp,total=v_total,observaciones=coalesce(p_datos->>'observaciones',''),
  empresa_snapshot=v_empresa,actualizado_en=now() where id=v_id;
 else
  insert into public.documentos(id,tipo,estado,numero,cliente_id,cliente_nombre,cliente_rtn,cliente_direccion,
  moneda_codigo,tasa_hnl,descuento,impuesto_pct,subtotal,impuesto,total,observaciones,
  cai_id,cai_texto,fecha_limite,rango_desde,rango_hasta,empresa_snapshot,creado_por)
  values(v_id,v_tipo,v_estado,v_numero,v_cliente,v_nombre,v_rtn,v_dir,v_mon.codigo,v_mon.tasa_hnl,
  v_desc,v_pct,v_sub,v_imp,v_total,coalesce(p_datos->>'observaciones',''),
  case when v_tipo='factura' then v_cai.id else null end,
  case when v_tipo='factura' then v_cai.cai else null end,
  case when v_tipo='factura' then v_cai.fecha_limite else null end,
  case when v_tipo='factura' then v_cai.desde else null end,
  case when v_tipo='factura' then v_cai.hasta else null end,v_empresa,auth.uid());
 end if;
 for v_fila in select value from jsonb_array_elements(p_items) loop
  v_idx:=v_idx+1;
  v_descripcion:=trim(v_fila->>'descripcion'); v_q:=(v_fila->>'cantidad')::numeric; v_p:=(v_fila->>'precio')::numeric;
  v_producto:=nullif(v_fila->>'producto_id','')::uuid;
  if v_producto is not null and not exists(select 1 from public.productos where id=v_producto) then raise exception 'Producto inexistente'; end if;
  if coalesce((v_fila->>'guardar_producto')::boolean,false) and v_producto is null then
    insert into public.productos(nombre,precio,codigo) values(v_descripcion,v_p,coalesce(v_fila->>'codigo','')) returning id into v_producto;
  end if;
  insert into public.documento_items(documento_id,producto_id,descripcion,cantidad,precio,total,orden)
  values(v_id,v_producto,v_descripcion,v_q,v_p,round(v_q*v_p,2),v_idx);
 end loop;
 return v_id;
end $$;

create or replace function public.anular_factura(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.es_admin() then raise exception 'Solo administración puede anular facturas'; end if;
 update public.documentos set estado='anulada',actualizado_en=now() where id=p_id and tipo='factura' and estado='emitida';
 if not found then raise exception 'Factura no encontrada o ya anulada'; end if;
end $$;
revoke execute on function public.guardar_documento(jsonb,jsonb,uuid) from public,anon;
revoke execute on function public.anular_factura(uuid) from public,anon;
grant execute on function public.guardar_documento(jsonb,jsonb,uuid) to authenticated;
grant execute on function public.anular_factura(uuid) to authenticated;

-- Activación segura del CAI en una única transacción, sin ventana sin autorización.
create or replace function public.activar_cai(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare v_reg public.autorizaciones_cai%rowtype;
begin
 if not public.tiene_permiso('cai') then raise exception 'No tiene permiso para administrar CAI'; end if;
 perform pg_advisory_xact_lock(21973011);
 select * into v_reg from public.autorizaciones_cai where id=p_id for update;
 if not found then raise exception 'CAI inexistente'; end if;
 if v_reg.fecha_limite<current_date then raise exception 'No puede activar un CAI vencido'; end if;
 if v_reg.siguiente>v_reg.hasta then raise exception 'No puede activar un CAI agotado'; end if;
 update public.autorizaciones_cai set activa=false where activa=true;
 update public.autorizaciones_cai set activa=true where id=p_id;
end $$;
revoke execute on function public.activar_cai(uuid) from public,anon;
grant execute on function public.activar_cai(uuid) to authenticated;
