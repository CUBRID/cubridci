import java.sql.*;             // For JDBC
import java.util.*;            // For collections
import java.io.*;              // For File I/O
import javax.xml.parsers.*;    // For XML Parsing
import org.w3c.dom.*;          // For DOM parsing

public class manual_test_result {
    
    public static void main(String[] args) {
        // Usage: java manual_test_result [base_version] <xml_file_path>
        if (args.length < 1) {
            System.out.println("Usage: java manual_test_result [base_version] <xml_file_path>");
            System.exit(0);
        }
        
        // DB connection information (modify as needed)
        String url = "jdbc:cubrid:127.0.0.1:30000:qaresu:::";
        String user = "manual_user";
        String password = "manual_user_123";
        
        String baseVersion;
        String xmlFilePath;
        
        if (args.length == 1) {
            // Only XML file path is provided, get the latest base version from DB
            xmlFilePath = args[0];
            baseVersion = getLatestBaseVersion(url, user, password);
            System.out.println("No base version provided. Using latest version from DB: " + baseVersion);
        } else {
            // Both base version and XML file path are provided
            baseVersion = args[0];
            xmlFilePath = args[1];
        }
        
        String cur_dir = System.getProperty("user.dir");
        String newFilename = cur_dir + "/" + baseVersion + "__" + "civersion" + "_new.csv";
        String dupFilename = cur_dir + "/" + baseVersion + "__" + "civersion" + "_dup.csv";
        
        // Retrieve baseline test cases from DB using the given base version.
        Set<String> baselineTestCases = getBaselineTestCases(baseVersion, url, user, password);
        
        // Parse test cases from an XML file.
        Set<String> xmlTestCases = parseXmlTestCases(xmlFilePath);
        
        // Extract new cases: Cases present in XML but not in baseline.
        Set<String> newTestCases = new HashSet<>(xmlTestCases);
        newTestCases.removeAll(baselineTestCases);
        
        // Write new test cases to CSV.
        writeTestCasesToCSV(newFilename, newTestCases);
        System.out.println("CSV file created: " + newFilename);
        
        // Extract duplicate cases: Cases present in both XML and baseline.
        Set<String> dupTestCases = new HashSet<>(xmlTestCases);
        dupTestCases.retainAll(baselineTestCases);
        
        // Write duplicate test cases to CSV.
        writeTestCasesToCSV(dupFilename, dupTestCases);
        System.out.println("CSV file created: " + dupFilename);
    }
    
    /**
     * Get the latest base version from the database.
     * 
     * @param url      The database URL
     * @param user     The database user
     * @param password The database password
     * @return The latest base version
     */
    public static String getLatestBaseVersion(String url, String user, String password) {
        String latestVersion = "unknown";
        try {
            // Load the CUBRID JDBC driver
            Class.forName("cubrid.jdbc.driver.CUBRIDDriver");
        } catch (ClassNotFoundException e) {
            System.err.println("Unable to load driver.");
            e.printStackTrace();
            return latestVersion;
        }
        
        try (Connection conn = DriverManager.getConnection(url, user, password)) {
            String sql = "select build_id " +
                    "from ( " +
                    "    SELECT 1 seq, test_build build_id " +
                    "    FROM shell_main " +
                    "    WHERE main_id = ( SELECT MAX(A.main_id) " +
                    "                      FROM shell_main  A, cubrid_build B " +
                    "                      WHERE A.os = 'linux' AND A.version= '64bits' AND A.category='shell' " +
                    "                        AND A.test_rate=100 " +
                    "                        AND A.test_build = B.build_id " +
                    "                        AND B.build_type = 'general' " +
                    "                    ) " +
                    "      AND test_build = ( SELECT MAX(A.test_build) " +
                    "                         FROM shell_main  A, cubrid_build B " +
                    "                         WHERE A.os = 'linux' AND A.version= '64bits' AND A.category='shell' " +
                    "                           AND A.test_rate=100 AND A.start_time > ( SYS_DATE - 60 ) " +
                    "                           AND A.test_build = B.build_id " +
                    "                           AND B.build_type = 'general' " +
                    "                       ) " +
                    "    UNION ALL " +
                    "    SELECT 2 seq, MAX(A.test_build)  build_id " +
                    "    FROM shell_main  A, cubrid_build B " +
                    "    WHERE A.os = 'linux' AND A.version= '64bits' AND A.category='shell' " +
                    "      AND A.test_rate=100 AND A.start_time > ( SYS_DATE - 60 ) " +
                    "      AND A.test_build = B.build_id " +
                    "      AND B.build_type = 'general' " +
                    "    ORDER BY 1 " +
                    "    LIMIT 1 " +
                    ")";
            
            try (Statement stmt = conn.createStatement();
                 ResultSet rs = stmt.executeQuery(sql)) {
                if (rs.next()) {
                    latestVersion = rs.getString(1).trim();
                }
            }
        } catch (Exception e) {
            System.err.println("Error getting latest base version:");
            e.printStackTrace();
        }
        
        return latestVersion;
    }
    
    /**
     * Retrieve baseline test cases from DB using the given base version.
     * 
     * @param baseVersion The baseline build version
     * @param url         JDBC URL for the DB
     * @param user        DB user id
     * @param password    DB password
     * @return Set of test case names
     */
    public static Set<String> getBaselineTestCases(String baseVersion, String url, String user, String password) {
        Set<String> testCases = new HashSet<>();
        try {
            // Load the CUBRID JDBC driver
            Class.forName("cubrid.jdbc.driver.CUBRIDDriver");
        } catch (ClassNotFoundException e) {
            System.err.println("Unable to load driver.");
            e.printStackTrace();
        }
        try (Connection conn = DriverManager.getConnection(url, user, password)) {
            String sql = "SELECT i.sce_id FROM verify_main m, verify_item i " +
                         "WHERE m.id = i.main_id " +
                         "AND m.build_id = ? " +
                         "AND m.sce_cat = 'shell' " +
                         "AND m.env_os = 'linux' " +
                         "AND m.sce_mcat = 'basic' " +
                         "AND m.build_bit = '64bits' " +
                         "ORDER BY i.sce_id";
            try (PreparedStatement pstmt = conn.prepareStatement(sql)) {
                pstmt.setString(1, baseVersion);
                try (ResultSet rs = pstmt.executeQuery()) {
                    while (rs.next()) {
                        String tcName = rs.getString(1).trim();
                        testCases.add(tcName);
                    }
                }
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
        return testCases;
    }
    
    /**
     * Parse test cases from an XML file.
     * The XML is expected to have elements like:
     * <testcase name="cubrid-testcases-private-ex/shell/_01_utility/..." time="...">
     * 
     * @param xmlFilePath The path to the XML file
     * @return Set of test case names formatted to match DB values
     */
    public static Set<String> parseXmlTestCases(String xmlFilePath) {
        Set<String> testCases = new HashSet<>();
        try {
            File xmlFile = new File(xmlFilePath);
            DocumentBuilderFactory dbFactory = DocumentBuilderFactory.newInstance();
            DocumentBuilder dBuilder = dbFactory.newDocumentBuilder();
            Document doc = dBuilder.parse(xmlFile);
            doc.getDocumentElement().normalize();
            
            NodeList nList = doc.getElementsByTagName("testcase");
            for (int i = 0; i < nList.getLength(); i++) {
                Node node = nList.item(i);
                if (node.getNodeType() == Node.ELEMENT_NODE) {
                    Element element = (Element) node;
                    
                    // Check if this testcase has a failure element
                    NodeList failureList = element.getElementsByTagName("failure");
                    if (failureList.getLength() > 0) {
                        // This is a failed test case, include it
                        String testCaseName = element.getAttribute("name").trim();
                        // Remove prefix if exists to match DB format.
                        String prefix = "cubrid-testcases-private-ex/";
                        if (testCaseName.startsWith(prefix)) {
                            testCaseName = testCaseName.substring(prefix.length());
                        }
                        testCases.add(testCaseName);
                        System.out.println("Failed testCase: " + testCaseName);
                    }
                }
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
        System.out.println("Failed testCases count: " + testCases.size());
        return testCases;
    }
    
    /**
     * Write given test cases to a CSV file with a predefined header.
     */
    public static void writeTestCasesToCSV(String csvOutputPath, Set<String> testCases) {
        try (PrintWriter writer = new PrintWriter(new FileWriter(csvOutputPath))) {
            // Write header.
            writer.println("Category,Case File,Review result(TC revise | Bug fix | Unstable TC),Comment");
            // Write test cases.
            for (String tc : testCases) {
                writer.println("shell," + escapeCsvField(tc) + ",,");
            }
        } catch (IOException e) {
            e.printStackTrace();
        }
    }
    
    /**
     * Escape special characters in CSV fields.
     */
    private static String escapeCsvField(String field) {
        if (field.contains(",") || field.contains("\"") || field.contains("\n")) {
            // Escape CSV field
            return "\"" + field.replace("\"", "\"\"") + "\"";
        }
        return field;
    }
}
