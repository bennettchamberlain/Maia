CREATE MIGRATION m14cqgnhheuc5iz6ktjxcdmv3bhlxghdbtxshodxcembgc5swm7emq
    ONTO m1uzsvz5cj4nifedylmz2tk3ht2sqbulqs2bcj6emxrzdt7ztsm4ja
{
  CREATE ABSTRACT TYPE default::Timeline EXTENDING default::Owned {
      ALTER PROPERTY data_class {
          SET default := 'timeline';
          SET OWNED;
          SET REQUIRED;
          SET TYPE std::str;
      };
      CREATE REQUIRED PROPERTY key: std::str;
      CREATE REQUIRED PROPERTY name: std::str;
      ALTER PROPERTY sensitive {
          SET default := true;
          SET OWNED;
          SET REQUIRED;
          SET TYPE std::bool;
      };
      CREATE CONSTRAINT std::exclusive ON ((.owner, .key));
      CREATE INDEX ON ((.owner, .key));
  };
  CREATE ABSTRACT TYPE default::TimelineEntry EXTENDING default::Owned {
      CREATE REQUIRED LINK timeline: default::Timeline {
          ON TARGET DELETE DELETE SOURCE;
      };
      CREATE PROPERTY body: std::str;
      ALTER PROPERTY data_class {
          SET default := 'timeline';
          SET OWNED;
          SET REQUIRED;
          SET TYPE std::str;
      };
      CREATE REQUIRED PROPERTY ended_at: std::datetime;
      CREATE REQUIRED PROPERTY kind: std::str;
      ALTER PROPERTY sensitive {
          SET default := true;
          SET OWNED;
          SET REQUIRED;
          SET TYPE std::bool;
      };
      CREATE PROPERTY source: std::str;
      CREATE PROPERTY source_id: std::str;
      CREATE REQUIRED PROPERTY started_at: std::datetime;
      CREATE PROPERTY title: std::str;
      CREATE PROPERTY topics: array<std::str> {
          SET default := (<array<std::str>>[]);
      };
      CREATE INDEX ON ((.timeline, .ended_at));
  };
  CREATE TYPE default::ConnectorEvent EXTENDING default::TimelineEntry {
      CREATE REQUIRED PROPERTY account: std::str;
      CREATE REQUIRED PROPERTY platform: std::str;
      CREATE CONSTRAINT std::exclusive ON ((.timeline, .source, .source_id));
  };
  CREATE TYPE default::CalendarEvent EXTENDING default::ConnectorEvent;
  ALTER TYPE default::ChatSession {
      CREATE LINK forked_from: default::ChatMessage {
          ON TARGET DELETE ALLOW;
      };
      CREATE REQUIRED PROPERTY summarized_through_seq: std::int32 {
          SET default := 0;
      };
      CREATE REQUIRED PROPERTY title_locked: std::bool {
          SET default := false;
      };
      CREATE PROPERTY topics: array<std::str> {
          SET default := (<array<std::str>>[]);
      };
  };
  CREATE TYPE default::ConnectionTimeline EXTENDING default::Timeline {
      CREATE REQUIRED PROPERTY account: std::str;
      CREATE REQUIRED PROPERTY platform: std::str;
  };
  CREATE TYPE default::MailEvent EXTENDING default::ConnectorEvent;
  CREATE TYPE default::Document EXTENDING default::Owned {
      ALTER PROPERTY data_class {
          SET default := 'file';
          SET OWNED;
          SET REQUIRED;
          SET TYPE std::str;
      };
      ALTER PROPERTY sensitive {
          SET default := true;
          SET OWNED;
          SET REQUIRED;
          SET TYPE std::bool;
      };
      CREATE PROPERTY body: std::str {
          SET default := '';
      };
      CREATE REQUIRED PROPERTY title: std::str;
  };
  CREATE TYPE default::FileSpan EXTENDING default::TimelineEntry {
      CREATE REQUIRED LINK document: default::Document {
          ON TARGET DELETE DELETE SOURCE;
      };
      CREATE CONSTRAINT std::exclusive ON ((.timeline, .document));
  };
  CREATE TYPE default::EntityTimeline EXTENDING default::Timeline {
      CREATE REQUIRED LINK subject: default::Thing {
          ON TARGET DELETE DELETE SOURCE;
      };
  };
  CREATE TYPE default::OntologySpan EXTENDING default::TimelineEntry {
      CREATE CONSTRAINT std::exclusive ON ((.timeline, .source, .source_id));
      CREATE LINK memory: default::MemoryItem {
          ON TARGET DELETE ALLOW;
      };
      CREATE REQUIRED LINK subject: default::Thing {
          ON TARGET DELETE DELETE SOURCE;
      };
  };
  CREATE TYPE default::PersonTimeline EXTENDING default::Timeline {
      CREATE REQUIRED LINK subject: default::Person {
          ON TARGET DELETE DELETE SOURCE;
      };
  };
  CREATE TYPE default::SessionSpan EXTENDING default::TimelineEntry {
      CREATE REQUIRED LINK session: default::ChatSession {
          ON TARGET DELETE DELETE SOURCE;
      };
      CREATE CONSTRAINT std::exclusive ON ((.timeline, .session));
  };
  CREATE TYPE default::UserTimeline EXTENDING default::Timeline;
};
