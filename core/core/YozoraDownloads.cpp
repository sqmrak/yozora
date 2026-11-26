#include "config.h"
#include "YozoraDownloads.h"
#include "yozora_core.h"
#include "YozoraCookies.h"
#include "YozoraCoreThread.h"
#include "CurlRequest.h"
#include "yozora_debug.h"
#include "yozora_transfer.h"
#include "CurlRequestClient.h"
#include "CurlResponse.h"
#include "HTTPHeaderNames.h"
#include "ResourceError.h"
#include "ResourceRequest.h"
#include "ResourceResponse.h"
#include "SharedBuffer.h"
#include <pthread.h>
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>
#include <wtf/RefCounted.h>
#include <wtf/text/MakeString.h>

namespace {

using namespace WebCore;
using namespace WTF::StringLiterals;

constexpr size_t maxItems = 50;
constexpr int maxRunning = 3;
constexpr unsigned maxRedirects = 10;

pthread_mutex_t items_lock = PTHREAD_MUTEX_INITIALIZER;
// the interface hears of a download that ended or paused, core thread only
yozora_download_observer observer_callback { nullptr };
void* observer_context { nullptr };

void notify(unsigned id, int state)
{
    if (observer_callback)
        observer_callback(id, state, observer_context);
}
// what the interface reads, newest last
std::vector<yozora_download>& items()
{
    static auto* list = new std::vector<yozora_download>;
    return *list;
}
std::string& directory()
{
    static auto* path = new std::string;
    return *path;
}
unsigned next_id { 1 };

bool is_active(int state)
{
    return state == YOZORA_DOWNLOAD_QUEUED || state == YOZORA_DOWNLOAD_RUNNING || state == YOZORA_DOWNLOAD_PAUSED;
}

yozora_download* find_item(unsigned id)
{
    for (auto& item : items()) {
        if (item.id == id)
            return &item;
    }
    return nullptr;
}

// the file name as a person sees it: no path, no control characters, no leading dots, at most 120 bytes cut at a character
std::string clean_name(const std::string& raw)
{
    std::string name;
    for (char c : raw) {
        unsigned char u = static_cast<unsigned char>(c);
        if (u < 0x20 || u == 0x7f || c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|')
            name += '_';
        else
            name += c;
    }
    size_t first = name.find_first_not_of(". ");
    name = first == std::string::npos ? std::string() : name.substr(first);
    while (!name.empty() && (name.back() == ' ' || name.back() == '.'))
        name.pop_back();
    if (name.size() > 120) {
        size_t cut = 120;
        while (cut > 0 && (static_cast<unsigned char>(name[cut]) & 0xc0) == 0x80)
            --cut;
        name.resize(cut);
    }
    return name.empty() ? std::string("download") : name;
}

std::string decode_percent(const std::string& text)
{
    std::string result;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '%' && i + 2 < text.size() && std::isxdigit(static_cast<unsigned char>(text[i + 1])) && std::isxdigit(static_cast<unsigned char>(text[i + 2]))) {
            result += static_cast<char>(std::stoi(text.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else
            result += text[i];
    }
    return result;
}

bool exists(const std::string& path)
{
    struct stat info;
    return !stat(path.c_str(), &info);
}

// name, then "name (1).ext", "name (2).ext": a download never replaces a file
std::string unique_name(const std::string& dir, const std::string& name)
{
    if (!exists(dir + "/" + name) && !exists(dir + "/" + name + ".part"))
        return name;
    size_t dot = name.rfind('.');
    std::string stem = dot == std::string::npos || dot == 0 ? name : name.substr(0, dot);
    std::string extension = dot == std::string::npos || dot == 0 ? std::string() : name.substr(dot);
    for (int n = 1; n < 1000; ++n) {
        std::string candidate = stem + " (" + std::to_string(n) + ")" + extension;
        if (!exists(dir + "/" + candidate) && !exists(dir + "/" + candidate + ".part"))
            return candidate;
    }
    return name + "." + std::to_string(next_id);
}

class Job;
void pump();

// the downloads that wait or run, core thread only
std::vector<Ref<Job>>& jobs()
{
    static auto* list = new std::vector<Ref<Job>>;
    return *list;
}

class Job final : public RefCounted<Job>, public CurlRequestClient {
public:
    static Ref<Job> create(unsigned id, const ResourceRequest& request, const String& suggestedName)
    {
        return adoptRef(*new Job(id, request, suggestedName));
    }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    unsigned id() const { return m_id; }
    bool running() const { return m_started; }
    bool paused() const { return m_paused; }

    void begin()
    {
        m_started = true;
        update([](yozora_download& item) { item.state = YOZORA_DOWNLOAD_RUNNING; });
        send();
    }
    void cancel()
    {
        finish(YOZORA_DOWNLOAD_CANCELLED, nullptr);
    }
    // the transfer stops and the part file stays on disk with what came, the place of the job in the running count goes to the next one
    void pause()
    {
        if (m_paused)
            return;
        Ref protectedThis { *this };
        m_paused = true;
        m_started = false;
        if (auto curl = std::exchange(m_curl, nullptr)) {
            curl->invalidateClient();
            curl->cancel();
        }
        if (m_file) {
            // a part file that did not close cleanly may be shorter than the count, so the download starts over when it resumes
            if (std::fclose(m_file))
                m_partIntact = false;
            m_file = nullptr;
        }
        update([](yozora_download& item) { item.state = YOZORA_DOWNLOAD_PAUSED; });
        notify(m_id, YOZORA_DOWNLOAD_PAUSED);
        pump();
    }
    void resume()
    {
        if (!m_paused)
            return;
        m_paused = false;
        update([](yozora_download& item) { item.state = YOZORA_DOWNLOAD_QUEUED; });
        pump();
    }

private:
    Job(unsigned id, const ResourceRequest& request, const String& suggestedName)
        : m_id(id), m_request(request), m_suggested(suggestedName.utf8().data()) { }

    template<typename Change>
    void update(Change change)
    {
        pthread_mutex_lock(&items_lock);
        if (auto* item = find_item(m_id))
            change(*item);
        pthread_mutex_unlock(&items_lock);
    }

    void send()
    {
        ResourceRequest request = m_request;
        // the cookies of the page that offered the file, the redirects of the download included
        if (auto cookies = YozoraCookies::requestHeader(request); !cookies.isEmpty())
            request.setHTTPHeaderField(HTTPHeaderName::Cookie, cookies);
        else
            request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
        request.setTimeoutInterval(30);
        // the rest of a paused file: only the same entity may be continued, so the first answer's validator
        // goes with it, and a part file that is not the size the count says is not continued at all
        m_ranged = false;
        if (m_received > 0 && !m_part.empty()) {
            struct stat info;
            if (m_resumable && m_partIntact && !stat(m_part.c_str(), &info) && static_cast<unsigned long long>(info.st_size) == m_received) {
                request.setHTTPHeaderField(HTTPHeaderName::Range, makeString("bytes="_s, m_received, '-'));
                request.setHTTPHeaderField(HTTPHeaderName::IfRange, String::fromUTF8(m_validator.c_str()));
                m_ranged = true;
            } else {
                restart_from_zero();
            }
        }
        m_curl = CurlRequest::create(request, *this, CurlRequest::CaptureNetworkLoadMetrics::Basic);
        m_curl->resume();
    }

    // the end of the job, whichever way: the file is closed and the part file renamed or removed
    void finish(int state, const char* error)
    {
        Ref protectedThis { *this };
        if (auto curl = std::exchange(m_curl, nullptr)) {
            curl->invalidateClient();
            curl->cancel();
        }
        bool wrote = m_partExists;
        if (m_file) {
            if (std::fclose(m_file) && state == YOZORA_DOWNLOAD_DONE) {
                state = YOZORA_DOWNLOAD_FAILED;
                error = "The file could not be written";
            }
            m_file = nullptr;
        }
        if (wrote && state == YOZORA_DOWNLOAD_DONE && std::rename(m_part.c_str(), m_path.c_str())) {
            state = YOZORA_DOWNLOAD_FAILED;
            error = "The file could not be saved";
        }
        if (wrote && state != YOZORA_DOWNLOAD_DONE)
            std::remove(m_part.c_str());
        update([&](yozora_download& item) {
            item.state = state;
            if (error)
                yozora_transfer_copy_text(item.error, sizeof(item.error), error);
        });
        auto& list = jobs();
        list.erase(std::remove_if(list.begin(), list.end(), [&](Ref<Job>& job) { return job.ptr() == this; }), list.end());
        notify(m_id, state);
        // this object may go with the last reference, the next one starts from the manager
        pump();
    }

    void fail(const char* message) { finish(YOZORA_DOWNLOAD_FAILED, message); }

    // forgets what came: the next request has no range and the file is written again from its first byte
    void restart_from_zero()
    {
        m_received = 0;
        m_resumable = false;
        if (m_file) {
            std::fclose(m_file);
            m_file = nullptr;
        }
        update([](yozora_download& item) { item.received = 0; });
    }

    void curlDidSendData(CurlRequest&, unsigned long long, unsigned long long) final { }

    void curlDidReceiveResponse(CurlRequest& request, CurlResponse&& response) final
    {
        Ref protectedThis { *this };
        if (m_curl.get() != &request)
            return;
        YozoraCookies::receive(m_request, response);
        ResourceResponse parsed(response);
        if (parsed.isRedirection() && parsed.httpStatusCode() != 304) {
            if (++m_redirects > maxRedirects)
                return fail("Too many redirects");
            URL next(m_request.url(), parsed.httpHeaderField(HTTPHeaderName::Location));
            if (!next.isValid() || !next.protocolIsInHTTPFamily() || !next.user().isEmpty() || !next.password().isEmpty())
                return fail("Redirect URL is not allowed");
            if (!protocolHostAndPortAreEqual(m_request.url(), next)) {
                m_request.removeHTTPHeaderField(HTTPHeaderName::Authorization);
                m_request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
            }
            if (m_request.url().protocolIs("https"_s) && next.protocolIs("http"_s))
                m_request.clearHTTPReferrer();
            m_request.setURL(WTF::move(next));
            request.invalidateClient();
            request.cancel();
            m_curl = nullptr;
            return send();
        }
        int status = parsed.httpStatusCode();
        if (status == 401 || status == 407)
            return fail("The server asks for a login");
        // the part on disk no longer matches what the server has: the file is fetched again from its first byte, once
        if (status == 416 && m_ranged && !m_rangeRetried) {
            m_rangeRetried = true;
            request.invalidateClient();
            request.cancel();
            m_curl = nullptr;
            restart_from_zero();
            return send();
        }
        if (status < 200 || status >= 300)
            return fail("The server did not give the file");
        bool partial = status == 206 && m_ranged;
        long long total = 0;
        if (partial) {
            // the server must continue exactly where the file ends
            long long first = -1, last = -1;
            auto range = parsed.httpHeaderField(HTTPHeaderName::ContentRange).utf8();
            if (std::sscanf(range.data(), "bytes %lld-%lld/%lld", &first, &last, &total) < 2 || first != static_cast<long long>(m_received))
                return fail("The server sent another part of the file");
            if (total <= 0)
                total = 0;
        } else {
            // a server that ignored the range, or an entity that changed, sends the whole file again
            if (m_received > 0)
                restart_from_zero();
            total = parsed.expectedContentLength() > 0 ? parsed.expectedContentLength() : 0;
            // an entity can be continued later when its validator is a strong one and the server takes ranges
            auto etag = parsed.httpHeaderField(HTTPHeaderName::ETag).utf8();
            auto modified = parsed.httpHeaderField(HTTPHeaderName::LastModified).utf8();
            bool strongTag = etag.length() && std::strncmp(etag.data(), "W/", 2);
            m_validator = strongTag ? std::string(etag.data()) : (modified.length() ? std::string(modified.data()) : std::string());
            m_resumable = !m_validator.empty() && parsed.httpHeaderField(HTTPHeaderName::AcceptRanges).convertToASCIILowercase().contains("bytes"_s);
        }
        // the name is chosen once: a resumed download keeps its file
        if (m_part.empty()) {
            // the name comes from the response when the page did not give one, and a file never replaces another
            std::string suggested = !m_suggested.empty() ? m_suggested : std::string(parsed.suggestedFilename().utf8().data());
            // without a name from the server the last part of the address names the file
            if (suggested.empty())
                suggested = decode_percent(std::string(m_request.url().lastPathComponent().toString().utf8().data()));
            std::string name = clean_name(suggested);
            std::string dir;
            pthread_mutex_lock(&items_lock);
            dir = directory();
            pthread_mutex_unlock(&items_lock);
            if (dir.empty())
                return fail("No folder for downloads");
            // a folder that exists already is the normal case, any other refusal is the reason shown for the file
            if (mkdir(dir.c_str(), 0755) && errno != EEXIST) {
                std::string reason = std::string("The downloads folder is not available: ") + std::strerror(errno);
                return fail(reason.c_str());
            }
            name = unique_name(dir, name);
            m_path = dir + "/" + name;
            m_part = m_path + ".part";
        }
        m_file = std::fopen(m_part.c_str(), partial ? "ab" : "wb");
        if (!m_file) {
            std::string reason = std::string("The file could not be created: ") + std::strerror(errno);
            return fail(reason.c_str());
        }
        m_partExists = true;
        m_partIntact = true;
        auto name = m_path.substr(m_path.rfind('/') + 1);
        update([&](yozora_download& item) {
            yozora_transfer_copy_text(item.name, sizeof(item.name), name.c_str());
            yozora_transfer_copy_text(item.path, sizeof(item.path), m_path.c_str());
            item.total = total;
            item.received = static_cast<long long>(m_received);
        });
        // the transfer waits for the client to accept the response before it sends the body
        request.completeDidReceiveResponse();
    }

    void curlDidReceiveData(CurlRequest& request, Ref<SharedBuffer>&& data) final
    {
        if (m_curl.get() != &request || !m_file)
            return;
        auto span = data->span();
        if (!span.empty() && std::fwrite(span.data(), 1, span.size(), m_file) != span.size())
            return fail(errno == ENOSPC ? "No space left on the device" : "The file could not be written");
        m_received += span.size();
        yozora_traffic_add(span.size(), 0);
        update([&](yozora_download& item) { item.received = static_cast<long long>(m_received); });
    }

    void curlDidComplete(CurlRequest& request, NetworkLoadMetrics&&) final
    {
        if (m_curl.get() != &request)
            return;
        if (!m_file)
            return fail("The server sent no file");
        finish(YOZORA_DOWNLOAD_DONE, nullptr);
    }

    void curlDidFailWithError(CurlRequest& request, ResourceError&& error, CertificateInfo&&) final
    {
        if (m_curl.get() != &request)
            return;
        auto text = error.localizedDescription().utf8();
        fail(text.length() ? text.data() : "The connection failed");
    }

    unsigned m_id;
    ResourceRequest m_request;
    std::string m_suggested;
    RefPtr<CurlRequest> m_curl;
    FILE* m_file { nullptr };
    std::string m_path;
    std::string m_part;
    unsigned long long m_received { 0 };
    unsigned m_redirects { 0 };
    bool m_started { false };
    bool m_paused { false };
    // the part file exists on disk, and is known to hold exactly m_received bytes
    bool m_partExists { false };
    bool m_partIntact { true };
    // the server takes ranges and gave a strong validator, which a continued request sends back in If-Range
    bool m_resumable { false };
    std::string m_validator;
    // the request in flight asks for the rest of the file, and a 416 to it has already been tried again once
    bool m_ranged { false };
    bool m_rangeRetried { false };
};

// the next waiting downloads take the free places
void pump()
{
    int running = 0;
    for (auto& job : jobs())
        running += job->running();
    for (auto& job : std::vector<Ref<Job>>(jobs())) {
        if (running >= maxRunning)
            break;
        if (job->running() || job->paused())
            continue;
        job->begin();
        ++running;
    }
}

}

namespace YozoraDownloads {

bool start(const ResourceRequest& original, const String& suggestedName)
{
    ResourceRequest request { URL(original.url()) };
    if (!request.url().protocolIsInHTTPFamily())
        return false;
    // the file is asked for the way the page asked for it, with the address of the page as the referrer
    request.setHTTPMethod("GET"_s);
    request.setHTTPReferrer(original.httpReferrer());
    request.setHTTPUserAgent(original.httpUserAgent());
    request.setFirstPartyForCookies(original.firstPartyForCookies());
    unsigned id;
    pthread_mutex_lock(&items_lock);
    auto& list = items();
    // finished entries make room for new ones, a running one is never dropped
    while (list.size() >= maxItems) {
        auto oldest = std::find_if(list.begin(), list.end(), [](auto& item) { return !is_active(item.state); });
        if (oldest == list.end())
            break;
        list.erase(oldest);
    }
    if (list.size() >= maxItems) {
        pthread_mutex_unlock(&items_lock);
        return false;
    }
    id = next_id++;
    yozora_download item { };
    item.id = id;
    item.state = YOZORA_DOWNLOAD_QUEUED;
    auto text = request.url().string().utf8();
    yozora_transfer_copy_text(item.name, sizeof(item.name), text.data());
    list.push_back(item);
    pthread_mutex_unlock(&items_lock);
    jobs().push_back(Job::create(id, request, suggestedName));
    pump();
    return true;
}

}

extern "C" void yozora_downloads_set_directory(const char* path)
{
    pthread_mutex_lock(&items_lock);
    directory() = path ? path : "";
    pthread_mutex_unlock(&items_lock);
}

extern "C" int yozora_downloads_list(yozora_download* out, int capacity)
{
    if (!out || capacity <= 0)
        return 0;
    pthread_mutex_lock(&items_lock);
    auto& list = items();
    int count = 0;
    // newest first
    for (auto at = list.rbegin(); at != list.rend() && count < capacity; ++at)
        out[count++] = *at;
    pthread_mutex_unlock(&items_lock);
    return count;
}

extern "C" void yozora_download_cancel(unsigned id)
{
    YozoraCoreThread::post([id] {
        for (auto& job : std::vector<Ref<Job>>(jobs())) {
            if (job->id() == id)
                job->cancel();
        }
    });
}

extern "C" void yozora_downloads_set_observer(yozora_download_observer observer, void* context)
{
    YozoraCoreThread::post([observer, context] {
        observer_callback = observer;
        observer_context = context;
    });
}

extern "C" void yozora_download_pause(unsigned id)
{
    YozoraCoreThread::post([id] {
        for (auto& job : std::vector<Ref<Job>>(jobs())) {
            if (job->id() == id)
                job->pause();
        }
    });
}

extern "C" void yozora_download_resume(unsigned id)
{
    YozoraCoreThread::post([id] {
        for (auto& job : std::vector<Ref<Job>>(jobs())) {
            if (job->id() == id)
                job->resume();
        }
    });
}

extern "C" void yozora_download_forget(unsigned id)
{
    pthread_mutex_lock(&items_lock);
    auto& list = items();
    list.erase(std::remove_if(list.begin(), list.end(), [&](auto& item) {
        return item.id == id && !is_active(item.state);
    }), list.end());
    pthread_mutex_unlock(&items_lock);
}
