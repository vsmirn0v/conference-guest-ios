#include <arpa/inet.h>
#include <netdb.h>

#include <chrono>
#include <iostream>
#include <memory>
#include <span>

#include "rtc_base/socket_server.h"
#include "rtc_base/ssl_adapter.h"
#include "rtc_base/thread.h"

// Real TLS handshakes through the candidate's native adapter and default trust
// policy. No custom verifier or ignore-certificate-errors option is installed.
int main(int argc, char** argv) {
  if (argc < 2 || !webrtc::InitializeSSL()) return 2;
  // The C runtime guarantees argv contains argc entries. Restrict the unsafe
  // pointer/count boundary to this conversion; indexed use is bounded below.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
  const std::span<char*> arguments(argv, static_cast<size_t>(argc));
#pragma clang diagnostic pop
  auto thread = webrtc::Thread::CreateWithSocketServer();
  if (!thread->WrapCurrent()) return 2;
  int failures = 0;
  for (size_t i = 1; i < arguments.size(); ++i) {
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* addresses = nullptr;
    if (getaddrinfo(arguments[i], "443", &hints, &addresses) != 0) {
      std::cout << arguments[i] << " dns-failed\n";
      ++failures;
      continue;
    }
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(addresses->ai_addr)->sin_addr,
              ip, sizeof(ip));
    freeaddrinfo(addresses);
    std::unique_ptr<webrtc::SSLAdapter> adapter(webrtc::SSLAdapter::Create(
        thread->socketserver()->CreateSocket(AF_INET, SOCK_STREAM)));
    if (!adapter) return 2;
    bool connected = false, closed = false;
    adapter->SubscribeConnectEvent(&connected, [&](webrtc::Socket*) { connected = true; });
    adapter->SubscribeCloseEvent(&closed, [&](webrtc::Socket*, int) { closed = true; });
    adapter->SetRole(webrtc::SSL_CLIENT);
    adapter->Connect(webrtc::SocketAddress(ip, 443));
    const int started = adapter->StartSSL(arguments[i]);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
    while (started == 0 && !connected && !closed && std::chrono::steady_clock::now() < deadline) {
      thread->ProcessMessages(20);
    }
    const bool passed = started == 0 && connected && !closed;
    std::cout << arguments[i] << (passed ? " verified\n" : " tls-failed\n");
    failures += !passed;
    adapter->Close();
  }
  thread->UnwrapCurrent();
  webrtc::CleanupSSL();
  return failures ? 1 : 0;
}
