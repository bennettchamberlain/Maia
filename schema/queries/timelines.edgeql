# Every timeline the caller owns: user, entity, person, connection.
# variables: $limit (int64)
select Timeline {
  id,
  key,
  name,
  type_name := .__type__.name,
  subject_name := [is EntityTimeline].subject.name,
  person_handle := [is PersonTimeline].subject.handle,
  platform := [is ConnectionTimeline].platform,
  account := [is ConnectionTimeline].account,
}
order by .name
limit <int64>$limit;
