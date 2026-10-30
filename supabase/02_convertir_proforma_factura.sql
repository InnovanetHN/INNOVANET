-- INNOVANET · Migración incremental (NO volver a ejecutar el esquema inicial).
-- Ejecutar una sola vez en Supabase SQL Editor. Conserva todos los documentos existentes.

alter table public.documentos
  add column if not exists origen_proforma_id uuid references public.documentos(id);

create unique index if not exists documentos_origen_proforma_unico
  on public.documentos(origen_proforma_id)
  where origen_proforma_id is not null;

create or replace function public.convertir_proforma_factura(p_proforma_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_origen public.documentos%rowtype;
  v_cai public.autorizaciones_cai%rowtype;
  v_factura uuid;
  v_numero text;
  v_hoy date := (now() at time zone 'America/Tegucigalpa')::date;
begin
  if auth.uid() is null or not public.tiene_permiso('documentos') then
    raise exception 'Sin permisos para emitir facturas';
  end if;
  if p_proforma_id is null then
    raise exception 'Indique una proforma válida';
  end if;

  -- Serializa conversiones concurrentes de la misma proforma.
  select * into v_origen from public.documentos
    where id = p_proforma_id for update;
  if not found or v_origen.tipo <> 'proforma' or v_origen.estado <> 'borrador' then
    raise exception 'La proforma no existe o no está disponible';
  end if;
  if exists (select 1 from public.documentos where origen_proforma_id = p_proforma_id) then
    raise exception 'Esta proforma ya tiene una factura emitida';
  end if;
  if not exists (select 1 from public.documento_items where documento_id = p_proforma_id) then
    raise exception 'La proforma no contiene artículos';
  end if;
  if trim(coalesce(v_origen.cliente_nombre,'')) = '' then
    raise exception 'La proforma no tiene cliente';
  end if;
  if not exists(select 1 from public.monedas where codigo=v_origen.moneda_codigo and activa) then
    raise exception 'La moneda de la proforma no está activa';
  end if;

  select * into v_cai from public.autorizaciones_cai
    where activa = true for update;
  if not found then
    raise exception 'No existe un CAI activo';
  end if;
  if v_hoy > v_cai.fecha_limite then
    raise exception 'El CAI activo está vencido';
  end if;
  if v_cai.siguiente < v_cai.desde or v_cai.siguiente > v_cai.hasta then
    raise exception 'El rango autorizado del CAI está agotado o es inválido';
  end if;

  v_numero := v_cai.establecimiento || '-' || v_cai.punto_emision || '-' ||
              v_cai.tipo_documento || '-' || lpad(v_cai.siguiente::text,8,'0');

  -- Número, copia fiscal y vínculo se guardan en la misma transacción.
  insert into public.documentos (
    tipo, estado, numero, fecha, cliente_id, cliente_nombre, cliente_rtn,
    cliente_direccion, moneda_codigo, tasa_hnl, descuento, impuesto_pct,
    subtotal, impuesto, total, observaciones, cai_id, cai_texto, fecha_limite,
    rango_desde, rango_hasta, empresa_snapshot, creado_por, origen_proforma_id
  ) values (
    'factura','emitida',v_numero,now(),v_origen.cliente_id,
    v_origen.cliente_nombre,v_origen.cliente_rtn,v_origen.cliente_direccion,
    v_origen.moneda_codigo,v_origen.tasa_hnl,v_origen.descuento,
    v_origen.impuesto_pct,v_origen.subtotal,v_origen.impuesto,v_origen.total,
    v_origen.observaciones,v_cai.id,v_cai.cai,v_cai.fecha_limite,
    v_cai.desde,v_cai.hasta,v_origen.empresa_snapshot,auth.uid(),p_proforma_id
  ) returning id into v_factura;

  insert into public.documento_items (documento_id,producto_id,descripcion,cantidad,precio,total,orden)
  select v_factura,producto_id,descripcion,cantidad,precio,total,orden
  from public.documento_items where documento_id = p_proforma_id;

  update public.autorizaciones_cai
     set siguiente = siguiente + 1 where id = v_cai.id;

  return v_factura;
end;
$$;

revoke all on function public.convertir_proforma_factura(uuid) from public, anon;
grant execute on function public.convertir_proforma_factura(uuid) to authenticated;

-- Bloquea la edición de una proforma que ya fue facturada, desde cualquier cliente.
-- Se conserva el RPC original y se agrega una validación antes de que lo ejecute.
create or replace function public.impedir_edicion_proforma_facturada()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.tipo = 'proforma' and exists (
    select 1 from public.documentos f where f.origen_proforma_id = old.id
  ) then
    raise exception 'La proforma ya fue facturada y no puede modificarse';
  end if;
  return new;
end $$;

drop trigger if exists bloquear_proforma_facturada on public.documentos;
create trigger bloquear_proforma_facturada
before update on public.documentos
for each row execute function public.impedir_edicion_proforma_facturada();

-- Comprobación (debe mostrar la nueva columna y función).
select column_name from information_schema.columns
 where table_schema='public' and table_name='documentos' and column_name='origen_proforma_id';
