import java.sql.*;             // For JDBC
import java.util.*;            // For collections
import java.io.*;              // For File I/O
import javax.xml.parsers.*;    // For XML Parsing
import org.w3c.dom.*;          // For DOM parsing

public class manual_test_result {
    
    public static void main(String[] args) {
        // Usage: java manual_test_result <base_version> <xml_file_path>
        if (args.length < 2) {
            System.out.println("Usage: java manual_test_result <base_version> <xml_file_path>");
            System.exit(0);
        }
        
        String baseVersion = args[0];
        String xmlFilePath = args[1];
        String cur_dir = System.getProperty("user.dir");
        String newFilename = cur_dir + "/" + baseVersion + "__" + "civersion" + "_new.csv";
        String dupFilename = cur_dir + "/" + baseVersion + "__" + "civersion" + "_dup.csv";
        
        // DB connection information (modify as needed)
        String url = "jdbc:cubrid:127.0.0.1:30000:qaresu:::";
        String user = "manual_user";
        String password = "manual_user_123";
        
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
        
        // Calculate intersection (duplicate test cases) between baseline and XML test cases.
        Set<String> dupTestCases = new HashSet<>(baselineTestCases);
        dupTestCases.retainAll(xmlTestCases);
        
        // Write duplicate test cases to CSV.
        writeTestCasesToCSV(dupFilename, dupTestCases);
        System.out.println("CSV file created: " + dupFilename);
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
                    String testCaseName = element.getAttribute("name").trim();
                    // Remove prefix if exists to match DB format.
                    String prefix = "cubrid-testcases-private-ex/";
                    if (testCaseName.startsWith(prefix)) {
                        testCaseName = testCaseName.substring(prefix.length());
                    }
                    testCases.add(testCaseName);
                }
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
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
