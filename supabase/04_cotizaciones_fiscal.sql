-- INNOVANET - Migración 04 · Fiscal + cotizaciones
-- Ejecutar después de 01 y 02. No elimina datos existentes.
BEGIN;
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT conname FROM pg_constraint WHERE conrelid='public.documentos'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%tipo%' LOOP
  EXECUTE format('ALTER TABLE public.documentos DROP CONSTRAINT %I',r.conname);
 END LOOP;
END $$;
ALTER TABLE public.documentos ADD CONSTRAINT documentos_tipo_valido CHECK(tipo IN ('factura','proforma','cotizacion'));
ALTER TABLE public.documentos
 ADD COLUMN IF NOT EXISTS orden_compra_exenta text NOT NULL DEFAULT '',
 ADD COLUMN IF NOT EXISTS constancia_registro_exonerado text NOT NULL DEFAULT '',
 ADD COLUMN IF NOT EXISTS registro_sag text NOT NULL DEFAULT '',
 ADD COLUMN IF NOT EXISTS importe_exonerado numeric(18,2) NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS importe_exento numeric(18,2) NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS gravado_15 numeric(18,2) NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS gravado_18 numeric(18,2) NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS impuesto_15 numeric(18,2) NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS impuesto_18 numeric(18,2) NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS origen_cotizacion_id uuid REFERENCES public.documentos(id);
CREATE UNIQUE INDEX IF NOT EXISTS documentos_origen_cotizacion_unico
 ON public.documentos(origen_cotizacion_id) WHERE origen_cotizacion_id IS NOT NULL;
INSERT INTO public.consecutivos(clave,siguiente) VALUES('COTIZACION',1) ON CONFLICT DO NOTHING;
-- Documentos previos: asignar desglose aproximado desde impuesto_pct y base existente.
UPDATE public.documentos SET
 importe_exento=CASE WHEN impuesto_pct=0 THEN greatest(0,subtotal-descuento) ELSE 0 END,
 gravado_15=CASE WHEN impuesto_pct=15 THEN greatest(0,subtotal-descuento) ELSE 0 END,
 gravado_18=CASE WHEN impuesto_pct=18 THEN greatest(0,subtotal-descuento) ELSE 0 END,
 impuesto_15=CASE WHEN impuesto_pct=15 THEN impuesto ELSE 0 END,
 impuesto_18=CASE WHEN impuesto_pct=18 THEN impuesto ELSE 0 END
WHERE tipo IN ('factura','proforma') AND importe_exento=0 AND importe_exonerado=0
 AND gravado_15=0 AND gravado_18=0 AND impuesto_15=0 AND impuesto_18=0;
create or replace function public.guardar_documento(p_datos jsonb, p_items jsonb, p_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare
 v_id uuid; v_tipo text; v_estado text; v_numero text; v_cai public.autorizaciones_cai%rowtype;
 v_seq bigint; v_fila jsonb; v_q numeric; v_p numeric; v_sub numeric:=0; v_desc numeric;
 v_pct numeric; v_base numeric; v_imp numeric; v_total numeric; v_mon public.monedas%rowtype;
 v_empresa jsonb; v_cliente uuid; v_nombre text; v_rtn text; v_dir text;
 v_guardar_cliente boolean; v_creado uuid; v_actual public.documentos%rowtype;
 v_producto uuid; v_descripcion text; v_idx integer:=0; v_nuevo_producto uuid;
 v_exon numeric;v_exent numeric;v_g15 numeric;v_g18 numeric;v_i15 numeric;v_i18 numeric;
begin
 if not public.tiene_permiso('documentos') then raise exception 'No tiene permiso para crear documentos'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>100 then raise exception 'Debe ingresar entre 1 y 100 artículos'; end if;
 v_tipo:=p_datos->>'tipo';
 if v_tipo not in ('factura','proforma','cotizacion') or v_tipo is null then raise exception 'Tipo de documento inválido'; end if;
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
 v_base:=v_sub-v_desc;
 if v_tipo='cotizacion' then
  v_imp:=round(v_base*v_pct/100,2);
  v_exon:=0;v_exent:=0;v_g15:=0;v_g18:=0;v_i15:=0;v_i18:=0;
 else
  v_exon:=coalesce(nullif(p_datos->>'importe_exonerado','')::numeric,0);
  v_exent:=coalesce(nullif(p_datos->>'importe_exento','')::numeric,case when v_pct=0 then v_base-v_exon else 0 end);
  v_g15:=coalesce(nullif(p_datos->>'gravado_15','')::numeric,case when v_pct=15 then v_base-v_exon-v_exent else 0 end);
  v_g18:=coalesce(nullif(p_datos->>'gravado_18','')::numeric,case when v_pct=18 then v_base-v_exon-v_exent else 0 end);
  if least(v_exon,v_exent,v_g15,v_g18)<0 or round(v_exon+v_exent+v_g15+v_g18,2)<>v_base then
   raise exception 'Los importes exonerados, exentos y gravados deben sumar la base después del descuento (%)',v_base;
  end if;
  v_i15:=round(v_g15*.15,2); v_i18:=round(v_g18*.18,2);
  v_imp:=v_i15+v_i18;
 end if;
 v_total:=v_base+v_imp;
 if p_id is not null then
   select * into v_actual from public.documentos where id=p_id for update;
   if not found then raise exception 'Documento no encontrado'; end if;
   if v_actual.tipo='factura' or v_actual.estado='emitida' or v_actual.estado='anulada' then raise exception 'Las facturas emitidas o anuladas no pueden modificarse'; end if;
   if v_tipo<>v_actual.tipo then raise exception 'No se puede cambiar el tipo durante edición'; end if;
   if exists(select 1 from public.documentos where origen_cotizacion_id=p_id or origen_proforma_id=p_id) then raise exception 'Documento convertido, edición bloqueada'; end if;
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
     update public.consecutivos set siguiente=siguiente+1 where clave=case when v_tipo='cotizacion' then 'COTIZACION' else 'PROFORMA' end returning siguiente-1 into v_seq;
     v_numero:=case when v_tipo='cotizacion' then 'COT-' else 'PRO-' end||lpad(v_seq::text,7,'0'); v_estado:='borrador';
   end if;
   v_id:=gen_random_uuid();
 end if;
 if p_id is not null then
  update public.documentos set cliente_id=v_cliente,cliente_nombre=v_nombre,cliente_rtn=v_rtn,cliente_direccion=v_dir,
  moneda_codigo=v_mon.codigo,tasa_hnl=v_mon.tasa_hnl,descuento=v_desc,impuesto_pct=v_pct,
  subtotal=v_sub,impuesto=v_imp,total=v_total,observaciones=coalesce(p_datos->>'observaciones',''),
  empresa_snapshot=v_empresa,actualizado_en=now(),
   orden_compra_exenta=left(coalesce(p_datos->>'orden_compra_exenta',''),100),
   constancia_registro_exonerado=left(coalesce(p_datos->>'constancia_registro_exonerado',''),100),
   registro_sag=left(coalesce(p_datos->>'registro_sag',''),100),
   importe_exonerado=v_exon,importe_exento=v_exent,gravado_15=v_g15,gravado_18=v_g18,impuesto_15=v_i15,impuesto_18=v_i18
   where id=v_id;
 else
  insert into public.documentos(id,tipo,estado,numero,cliente_id,cliente_nombre,cliente_rtn,cliente_direccion,
  moneda_codigo,tasa_hnl,descuento,impuesto_pct,subtotal,impuesto,total,observaciones,
  cai_id,cai_texto,fecha_limite,rango_desde,rango_hasta,empresa_snapshot,creado_por,
  orden_compra_exenta,constancia_registro_exonerado,registro_sag,importe_exonerado,importe_exento,gravado_15,gravado_18,impuesto_15,impuesto_18)
  values(v_id,v_tipo,v_estado,v_numero,v_cliente,v_nombre,v_rtn,v_dir,v_mon.codigo,v_mon.tasa_hnl,
  v_desc,v_pct,v_sub,v_imp,v_total,coalesce(p_datos->>'observaciones',''),
  case when v_tipo='factura' then v_cai.id else null end,
  case when v_tipo='factura' then v_cai.cai else null end,
  case when v_tipo='factura' then v_cai.fecha_limite else null end,
  case when v_tipo='factura' then v_cai.desde else null end,
  case when v_tipo='factura' then v_cai.hasta else null end,v_empresa,auth.uid(),
  left(coalesce(p_datos->>'orden_compra_exenta',''),100),left(coalesce(p_datos->>'constancia_registro_exonerado',''),100),left(coalesce(p_datos->>'registro_sag',''),100),v_exon,v_exent,v_g15,v_g18,v_i15,v_i18);
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


CREATE OR REPLACE FUNCTION public.convertir_cotizacion(p_cotizacion_id uuid,p_destino text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v public.documentos%rowtype; v_items jsonb; v_id uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.tiene_permiso('documentos') THEN RAISE EXCEPTION 'Sin permisos';END IF;
 IF p_destino NOT IN ('proforma','factura') OR p_destino IS NULL THEN RAISE EXCEPTION 'Destino inválido';END IF;
 SELECT * INTO v FROM public.documentos WHERE id=p_cotizacion_id FOR UPDATE;
 IF NOT FOUND OR v.tipo<>'cotizacion' OR v.estado<>'borrador' THEN RAISE EXCEPTION 'Cotización no disponible';END IF;
 IF EXISTS(SELECT 1 FROM public.documentos WHERE origen_cotizacion_id=v.id) THEN RAISE EXCEPTION 'Cotización ya convertida';END IF;
 SELECT jsonb_agg(jsonb_build_object('producto_id',producto_id,'descripcion',descripcion,'cantidad',cantidad,'precio',precio,'guardar_producto',false,'codigo','') ORDER BY orden)
 INTO v_items FROM public.documento_items WHERE documento_id=v.id;
 IF v_items IS NULL THEN RAISE EXCEPTION 'Cotización sin productos';END IF;
 v_id:=public.guardar_documento(
  jsonb_build_object('tipo',p_destino,'cliente_id',v.cliente_id,'cliente_nombre',v.cliente_nombre,'cliente_rtn',v.cliente_rtn,
  'cliente_direccion',v.cliente_direccion,'moneda_codigo',v.moneda_codigo,'descuento',v.descuento,'impuesto_pct',v.impuesto_pct,
  'observaciones',v.observaciones,'orden_compra_exenta',v.orden_compra_exenta,
  'constancia_registro_exonerado',v.constancia_registro_exonerado,'registro_sag',v.registro_sag,
  'importe_exonerado',v.importe_exonerado,'importe_exento',v.importe_exento,
  'gravado_15',CASE WHEN v.gravado_15=0 THEN NULL ELSE to_jsonb(v.gravado_15) END,
  'gravado_18',CASE WHEN v.gravado_18=0 THEN NULL ELSE to_jsonb(v.gravado_18) END),v_items,NULL);
 UPDATE public.documentos SET origen_cotizacion_id=v.id WHERE id=v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.convertir_cotizacion(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.convertir_cotizacion(uuid,text) TO authenticated;
-- Conversión proforma->factura existente: copiar los campos guardados a la factura recién emitida dentro de la misma transacción.
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
    rango_desde, rango_hasta, empresa_snapshot, creado_por, origen_proforma_id,
    orden_compra_exenta,constancia_registro_exonerado,registro_sag,importe_exonerado,importe_exento,gravado_15,gravado_18,impuesto_15,impuesto_18
  ) values (
    'factura','emitida',v_numero,now(),v_origen.cliente_id,
    v_origen.cliente_nombre,v_origen.cliente_rtn,v_origen.cliente_direccion,
    v_origen.moneda_codigo,v_origen.tasa_hnl,v_origen.descuento,
    v_origen.impuesto_pct,v_origen.subtotal,v_origen.impuesto,v_origen.total,
    v_origen.observaciones,v_cai.id,v_cai.cai,v_cai.fecha_limite,
    v_cai.desde,v_cai.hasta,v_origen.empresa_snapshot,auth.uid(),p_proforma_id,
    v_origen.orden_compra_exenta,v_origen.constancia_registro_exonerado,v_origen.registro_sag,
    v_origen.importe_exonerado,v_origen.importe_exento,v_origen.gravado_15,v_origen.gravado_18,v_origen.impuesto_15,v_origen.impuesto_18
  ) returning id into v_factura;

  insert into public.documento_items (documento_id,producto_id,descripcion,cantidad,precio,total,orden)
  select v_factura,producto_id,descripcion,cantidad,precio,total,orden
  from public.documento_items where documento_id = p_proforma_id;

  update public.autorizaciones_cai
     set siguiente = siguiente + 1 where id = v_cai.id;

  return v_factura;
end;
$$;


NOTIFY pgrst,'reload schema';
COMMIT;
