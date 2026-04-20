import logging
import json
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone


def main(events) -> None:
    endpoint = os.environ.get('OPENOBSERVE_ENDPOINT', '')
    access_key = os.environ.get('OPENOBSERVE_ACCESS_KEY', '')
    stream_name = os.environ.get('STREAM_NAME', 'azure-activity-logs')

    if not endpoint or not access_key:
        logging.error('Missing OPENOBSERVE_ENDPOINT or OPENOBSERVE_ACCESS_KEY env vars')
        return

    all_records = []
    event_list = events if isinstance(events, list) else [events]

    for event in event_list:
        try:
            body = event.get_body().decode('utf-8')

            data = json.loads(body)

            if isinstance(data, dict) and 'records' in data:
                for record in data['records']:
                    record['_timestamp'] = (
                        record.get('time') or
                        record.get('eventTimestamp') or
                        datetime.now(timezone.utc).isoformat()
                    )
                    record['_source'] = 'azure-activity-log'
                    record['_stream'] = stream_name
                    all_records.append(record)
            elif isinstance(data, list):
                for item in data:
                    item['_timestamp'] = (
                        item.get('time') or
                        item.get('eventTimestamp') or
                        datetime.now(timezone.utc).isoformat()
                    )
                    item['_source'] = 'azure-activity-log'
                    item['_stream'] = stream_name
                    all_records.append(item)
            else:
                data['_timestamp'] = (
                    data.get('time') or
                    data.get('eventTimestamp') or
                    datetime.now(timezone.utc).isoformat()
                )
                data['_source'] = 'azure-activity-log'
                data['_stream'] = stream_name
                all_records.append(data)

        except Exception as exc:
            logging.error('Error parsing Event Hub message: %s', exc)

    if not all_records:
        logging.info('No records to forward')
        return

    payload = json.dumps(all_records).encode('utf-8')
    logging.info('Forwarding %d Activity Log records to OpenObserve', len(all_records))

    req = urllib.request.Request(
        endpoint,
        data=payload,
        method='POST',
        headers={
            'Content-Type': 'application/json',
            'Authorization': 'Basic ' + access_key,
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            logging.info('Successfully sent %d records to OpenObserve. HTTP %s',
                         len(all_records), resp.status)
    except urllib.error.HTTPError as exc:
        logging.error('OpenObserve HTTP error %s: %s', exc.code, exc.reason)
        raise
    except Exception as exc:
        logging.error('Failed to send to OpenObserve: %s', exc)
        raise
