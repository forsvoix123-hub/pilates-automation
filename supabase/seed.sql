-- Demo data only. Run in a test project after the schema migration.
-- Non-ASCII text uses Unicode escapes so the file is safe to paste.
-- Client rows have no linked Auth accounts and no admin access.
begin;
set local standard_conforming_strings = on;

insert into public.clients (id, name, email) values
  ('10000000-0000-4000-8000-000000000001', U&'\0410\043b\0435\043a\0441\0430\043d\0434\0440\0430 \041c\043e\0440\043e\0437\043e\0432\0430', 'alexandra@example.com'),
  ('10000000-0000-4000-8000-000000000002', U&'\041c\0430\0440\0438\044f \0412\043e\043b\043a\043e\0432\0430', 'maria@example.com'),
  ('10000000-0000-4000-8000-000000000003', U&'\0415\043b\0435\043d\0430 \0421\043e\043a\043e\043b\043e\0432\0430', 'elena@example.com')
on conflict (id) do nothing;

insert into public.trainers (id, name, direction) values
  ('20000000-0000-4000-8000-000000000001', 'Anna', 'pilates'),
  ('20000000-0000-4000-8000-000000000002', 'Mila', 'pilates'),
  ('20000000-0000-4000-8000-000000000003', 'Sofia', 'beauty')
on conflict (id) do nothing;

insert into public.services (id, direction, name, description, duration_minutes, price_amount) values
  ('30000000-0000-4000-8000-000000000001', 'pilates',
   $json${"ru":"\u041f\u0438\u043b\u0430\u0442\u0435\u0441 \u043d\u0430 \u0440\u0435\u0444\u043e\u0440\u043c\u0435\u0440\u0435","en":"Reformer Pilates","sr":"Pilates na reformeru"}$json$::jsonb,
   $json${"ru":"\u0420\u0430\u0431\u043e\u0442\u0430 \u0441 \u043e\u0441\u0430\u043d\u043a\u043e\u0439, \u0431\u0430\u043b\u0430\u043d\u0441\u043e\u043c \u0438 \u0433\u043b\u0443\u0431\u043e\u043a\u0438\u043c\u0438 \u043c\u044b\u0448\u0446\u0430\u043c\u0438.","en":"Work on posture, balance and deep muscles.","sr":"Rad na dr\u017eanju, ravnote\u017ei i dubokim mi\u0161i\u0107ima."}$json$::jsonb, 50, 2400),
  ('30000000-0000-4000-8000-000000000002', 'pilates',
   $json${"ru":"\u041f\u0438\u043b\u0430\u0442\u0435\u0441 \u043d\u0430 \u043a\u043e\u0432\u0440\u0438\u043a\u0435","en":"Mat Pilates","sr":"Pilates na prostirci"}$json$::jsonb,
   $json${"ru":"\u041c\u044f\u0433\u043a\u043e\u0435 \u0443\u043a\u0440\u0435\u043f\u043b\u0435\u043d\u0438\u0435 \u0442\u0435\u043b\u0430 \u0447\u0435\u0440\u0435\u0437 \u043a\u043e\u043d\u0442\u0440\u043e\u043b\u0438\u0440\u0443\u0435\u043c\u044b\u0435 \u0434\u0432\u0438\u0436\u0435\u043d\u0438\u044f.","en":"Build strength gently through controlled movement.","sr":"Ne\u017eno ja\u010danje tela kroz kontrolisane pokrete."}$json$::jsonb, 55, 1800),
  ('30000000-0000-4000-8000-000000000003', 'beauty',
   $json${"ru":"\u041c\u0430\u0441\u0441\u0430\u0436 \u043b\u0438\u0446\u0430","en":"Facial massage","sr":"Masa\u017ea lica"}$json$::jsonb,
   $json${"ru":"\u0420\u0430\u0441\u0441\u043b\u0430\u0431\u043b\u044f\u044e\u0449\u0438\u0439 \u0440\u0443\u0447\u043d\u043e\u0439 \u0443\u0445\u043e\u0434 \u0434\u043b\u044f \u043b\u0438\u0446\u0430 \u0438 \u0448\u0435\u0438.","en":"Relaxing hands-on care for the face and neck.","sr":"Opu\u0161taju\u0107a ru\u010dna nega lica i vrata."}$json$::jsonb, 45, 3900),
  ('30000000-0000-4000-8000-000000000004', 'beauty',
   $json${"ru":"\u0423\u0432\u043b\u0430\u0436\u043d\u044f\u044e\u0449\u0438\u0439 \u0443\u0445\u043e\u0434","en":"Hydrating facial","sr":"Hidratantni tretman lica"}$json$::jsonb,
   $json${"ru":"\u0414\u0435\u043b\u0438\u043a\u0430\u0442\u043d\u043e\u0435 \u043e\u0447\u0438\u0449\u0435\u043d\u0438\u0435 \u0438 \u0443\u0432\u043b\u0430\u0436\u043d\u0435\u043d\u0438\u0435 \u043a\u043e\u0436\u0438.","en":"Gentle cleansing and hydration.","sr":"Blago \u010di\u0161\u0107enje i hidratacija ko\u017ee."}$json$::jsonb, 60, 4900)
on conflict (id) do nothing;

insert into public.trainer_services (trainer_id, service_id, direction) values
  ('20000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 'pilates'),
  ('20000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', 'pilates'),
  ('20000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000002', 'pilates'),
  ('20000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000003', 'beauty'),
  ('20000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000004', 'beauty')
on conflict (trainer_id, service_id) do nothing;

-- The demo schedule uses Central European winter time (+01:00).
insert into public.classes (id, trainer_id, service_id, starts_at, kind, capacity) values
  ('40000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', '2026-12-03 09:30+01', 'group', 5),
  ('40000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000002', '2026-12-03 12:00+01', 'group', 8),
  ('40000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', '2026-12-04 18:30+01', 'group', 5),
  ('40000000-0000-4000-8000-000000000004', '20000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000003', '2026-12-03 14:00+01', 'individual', 1),
  ('40000000-0000-4000-8000-000000000005', '20000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000004', '2026-12-04 11:00+01', 'individual', 1),
  ('40000000-0000-4000-8000-000000000006', '20000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', '2026-12-04 15:00+01', 'individual', 1)
on conflict (id) do nothing;

insert into public.bookings (id, client_id, class_id, status) values
  ('50000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002', '40000000-0000-4000-8000-000000000001', 'confirmed'),
  ('50000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000003', '40000000-0000-4000-8000-000000000004', 'confirmed')
on conflict do nothing;

insert into public.memberships (id, client_id, name, total_sessions, remaining_sessions) values
  ('60000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', U&'\041f\0438\043b\0430\0442\0435\0441 \00b7 8 \0437\0430\043d\044f\0442\0438\0439', 8, 6),
  ('60000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000002', U&'\041f\0438\043b\0430\0442\0435\0441 \00b7 4 \0437\0430\043d\044f\0442\0438\044f', 4, 3)
on conflict (id) do nothing;

-- Also support seeding a fresh database after the membership booking migration.
do $$
begin
  if to_regprocedure('harmony_private.group_membership(uuid,uuid,boolean)') is not null then
    update public.memberships set direction = 'pilates'
    where id in ('60000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002')
      and direction is null;
    perform 1 from public.classes
    where id = '40000000-0000-4000-8000-000000000001' and status = 'scheduled' and starts_at >= now()
    for update;
    if found then
      update public.bookings b
      set membership_id = harmony_private.group_membership(b.client_id, b.class_id, false)
      where b.id = '50000000-0000-4000-8000-000000000001' and b.status = 'confirmed' and b.membership_id is null;
    end if;
  end if;
end;
$$;

commit;
