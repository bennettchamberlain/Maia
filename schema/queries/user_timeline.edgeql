# Entries on the caller's user timeline, newest end first.
# variables: $limit (int64)
select TimelineEntry {
  id,
  kind,
  title,
  body,
  topics,
  source,
  source_id,
  started_at,
  ended_at,
  session_id := [is SessionSpan].session.id,
  platform := [is ConnectorEvent].platform,
  account := [is ConnectorEvent].account,
}
filter .timeline.id = (
  select UserTimeline filter .key = 'user' limit 1
).id
  and .kind != 'ontology'
order by .ended_at desc
limit <int64>$limit;
