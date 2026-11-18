# Events on one timeline after a moment. Agents read this.
# variables: $timeline (uuid), $after (datetime), $limit (int64)
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
  and .started_at > <datetime>$after
order by .started_at asc
limit <int64>$limit;
