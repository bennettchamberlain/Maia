# Newest events on one timeline. The memory page reads this.
# variables: $timeline (uuid), $limit (int64)
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
filter .timeline.id = <uuid>$timeline
order by .ended_at desc
limit <int64>$limit;
