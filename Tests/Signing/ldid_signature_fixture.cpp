#include "../../Shared/libProvision/ldid/ldid.hpp"

#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>

static std::string ReadFile(const char *path) {
    std::ifstream input(path, std::ios::binary);
    if (!input)
        throw std::runtime_error(std::string("Could not open ") + path);
    return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

int main(int argc, char *argv[]) {
    if (argc == 4 && std::string(argv[1]) == "--bundle") {
        try {
            const std::string entitlements(ReadFile(argv[3]));
            ldid::DiskFolder folder(argv[2]);
            ldid::Sign("", folder, "", "",
                       ldid::fun([&](const std::string &relativeBundlePath,
                                    const std::string &existingEntitlements) -> std::string {
                           return relativeBundlePath.empty() ? entitlements : existingEntitlements;
                       }),
                       ldid::fun([](const std::string &) {}),
                       ldid::fun([](double) {}));
        } catch (const std::exception &error) {
            std::cerr << error.what() << '\n';
            return 1;
        } catch (const char *error) {
            std::cerr << error << '\n';
            return 1;
        }
        return 0;
    }

    if (argc != 4) {
        std::cerr << "usage: " << argv[0] << " input-binary entitlements.plist output-binary\n"
                  << "       " << argv[0] << " --bundle app-bundle entitlements.plist\n";
        return 64;
    }

    try {
        const std::string binary(ReadFile(argv[1]));
        const std::string entitlements(ReadFile(argv[2]));
        std::stringbuf output;
        ldid::Slots slots;

        ldid::Sign(binary.data(), binary.size(), output,
                   "com.b4db1r3.reprovision-signature-fixture",
                   entitlements, "", "", slots,
                   ldid::fun([](double) {}));

        std::ofstream signedBinary(argv[3], std::ios::binary | std::ios::trunc);
        const std::string result(output.str());
        signedBinary.write(result.data(), result.size());
        if (!signedBinary)
            throw std::runtime_error(std::string("Could not write ") + argv[3]);
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    } catch (const char *error) {
        std::cerr << error << '\n';
        return 1;
    }

    return 0;
}
