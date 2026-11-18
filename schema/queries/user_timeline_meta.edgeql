# The caller's user timeline, the one the memory column shows.
select UserTimeline { id, key, name }
filter .key = 'user'
limit 1;
